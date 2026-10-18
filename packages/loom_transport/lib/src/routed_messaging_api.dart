import 'dart:async';
import 'dart:io';

import 'package:loom_models/loom_models.dart';
import 'package:loom_protocol/loom_protocol.dart';

import 'connectivity.dart';
import 'network_generation.dart';
import 'route_policy.dart';

/// No currently verified Home-Node route was available to attempt.
///
/// This is intentionally distinct from a protocol or authorization rejection:
/// ordinary Send may use durable DTN for this condition, while a definitive
/// server response must remain authoritative.
class LoomMessagingTransportUnavailable extends LoomProtocolException {
  const LoomMessagingTransportUnavailable(super.message);
}

typedef LoomMessagingRoutesRefresher = Future<List<LoomMessagingRoute>>
    Function();

class LoomMessagingRoute {
  const LoomMessagingRoute({
    required this.candidate,
    required this.api,
    this.refreshOnNetworkChange,
  });

  final LoomRouteCandidate candidate;
  final LoomMessagingApi api;

  /// Re-discovers ephemeral LAN addresses while preserving trusted Node
  /// identity. Normally attached to the canonical Home route only.
  final LoomMessagingRoutesRefresher? refreshOnNetworkChange;
}

class LoomRoutedMessagingApi implements LoomMessagingApi {
  LoomRoutedMessagingApi({
    required this.homeNodeId,
    required List<LoomMessagingRoute> routes,
    LoomRoutePolicy? policy,
    this.sendAttemptBudget = const Duration(seconds: 8),
    this.lanFallbackBudget = const Duration(seconds: 1),
    this.failedRouteCooldown = const Duration(seconds: 30),
  })  : _routes = List<LoomMessagingRoute>.unmodifiable(routes),
        _routesGeneration = LoomDefaultNetworkGeneration.current.generation,
        policy = policy ?? const LoomRoutePolicy();

  final String homeNodeId;
  List<LoomMessagingRoute> _routes;
  int _routesGeneration;
  final LoomRoutePolicy policy;

  /// One wall-clock budget for LAN discovery plus every online route attempted
  /// by a single send. Individual protocol stage deadlines still apply inside
  /// each route and may fail sooner.
  final Duration sendAttemptBudget;

  /// Reserve time for HTTPS when a previously discovered LAN address stalls.
  /// Attachment uploads retain their protocol deadlines.
  final Duration lanFallbackBudget;
  final Duration failedRouteCooldown;
  final Map<String, DateTime> _failedUntil = {};

  LoomConnectivityState state = LoomConnectivityState.nodeUnreachable;
  String? activeRouteId;

  List<LoomMessagingRoute> _ordered() {
    final selection = policy.select(
      _routes.map((route) => route.candidate).toList(),
      homeNodeId: homeNodeId,
    );
    state = selection.state;
    final ordered = selection.ordered
        .map(
          (candidate) =>
              _routes.firstWhere((route) => route.candidate.id == candidate.id),
        )
        .toList();
    final now = DateTime.now();
    _failedUntil.removeWhere((_, until) => !until.isAfter(now));
    // Keep failed routes as a last resort for offline LAN-only operation, but
    // do not pay their timeout again on every message while HTTPS is healthy.
    return [
      ...ordered.where(
        (route) => !_failedUntil.containsKey(route.candidate.id),
      ),
      ...ordered.where((route) => _failedUntil.containsKey(route.candidate.id)),
    ];
  }

  Duration? _remaining(Stopwatch? clock, Duration? budget) {
    if (clock == null || budget == null) return null;
    final remaining = budget - clock.elapsed;
    return remaining > Duration.zero ? remaining : Duration.zero;
  }

  void _discardStaleLanRoutes(int generation) {
    _failedUntil.clear();
    for (final route in _routes) {
      if (route.candidate.kind == LoomRouteKind.localNetwork &&
          route.api is LoomAbortableTransport) {
        (route.api as LoomAbortableTransport).abortActiveTransport(
          'network_generation',
        );
      }
    }
    _routes = List<LoomMessagingRoute>.unmodifiable(
      _routes.where(
        (route) => route.candidate.kind != LoomRouteKind.localNetwork,
      ),
    );
    LoomTransportDiagnostics.event(
      'stale_lan_routes_invalidated',
      networkGeneration: generation,
    );
  }

  Future<void> _refreshRoutesIfStale({
    Stopwatch? clock,
    Duration? budget,
  }) async {
    final generation = LoomDefaultNetworkGeneration.current.generation;
    if (generation == _routesGeneration) return;
    final refresher = _routes
        .map((route) => route.refreshOnNetworkChange)
        .whereType<LoomMessagingRoutesRefresher>()
        .firstOrNull;
    _discardStaleLanRoutes(generation);
    _routesGeneration = generation;
    if (refresher == null) return;

    final remaining = _remaining(clock, budget);
    if (remaining == Duration.zero) {
      throw TimeoutException('Loom online send attempt budget expired', budget);
    }
    try {
      final refreshFuture = refresher();
      final refreshed = remaining == null
          ? await refreshFuture
          : await refreshFuture.timeout(remaining);
      if (LoomDefaultNetworkGeneration.current.generation != generation) {
        return;
      }
      _routes = List<LoomMessagingRoute>.unmodifiable(refreshed);
      _routesGeneration = generation;
      LoomTransportDiagnostics.event(
        'lan_routes_refreshed',
        networkGeneration: generation,
      );
    } on TimeoutException {
      rethrow;
    } catch (_) {
      // Discovery is opportunistic. The canonical Home route retained above is
      // still allowed to prove reachability within the remaining send budget.
    }
  }

  Future<T> _try<T>(
    Future<T> Function(LoomMessagingApi api) action, {
    Duration? budget,
    String? sendAttemptId,
    bool boundLanFallback = true,
  }) async {
    final clock = budget == null ? null : (Stopwatch()..start());
    Object? lastError;

    while (true) {
      await _refreshRoutesIfStale(clock: clock, budget: budget);
      final attemptGeneration = LoomDefaultNetworkGeneration.current.generation;
      final ordered = _ordered();
      if (ordered.isEmpty) {
        state = LoomConnectivityState.nodeUnreachable;
        throw const LoomMessagingTransportUnavailable(
          'No verified route to Home Node',
        );
      }

      var generationChanged = false;
      for (final route in ordered) {
        final remaining = _remaining(clock, budget);
        if (remaining == Duration.zero) {
          state = LoomConnectivityState.nodeUnreachable;
          throw TimeoutException(
            'Loom online send attempt budget expired',
            budget,
          );
        }
        Duration? routeBudget = remaining;
        if (boundLanFallback &&
            ordered.length > 1 &&
            route.candidate.kind == LoomRouteKind.localNetwork) {
          // A LAN timeout must leave at least half of the remaining send
          // budget for the other verified Home Node route.
          final reserve = remaining == null
              ? lanFallbackBudget
              : Duration(microseconds: remaining.inMicroseconds ~/ 2);
          routeBudget =
              reserve < lanFallbackBudget ? reserve : lanFallbackBudget;
        }
        final routeCategory = route.candidate.kind.name;
        LoomTransportDiagnostics.event(
          'route_attempt_started',
          sendAttemptId: sendAttemptId,
          networkGeneration: attemptGeneration,
          routeCategory: routeCategory,
        );
        try {
          final pending = action(route.api);
          final value = routeBudget == null
              ? await pending
              : await pending.timeout(
                  routeBudget,
                  onTimeout: () {
                    if (route.api is LoomAbortableTransport) {
                      (route.api as LoomAbortableTransport)
                          .abortActiveTransport('route_budget');
                    }
                    throw TimeoutException(
                      'Loom route attempt budget expired',
                      routeBudget,
                    );
                  },
                );
          if (LoomDefaultNetworkGeneration.current.generation !=
              attemptGeneration) {
            if (route.api is LoomAbortableTransport) {
              (route.api as LoomAbortableTransport).abortActiveTransport(
                'network_generation',
              );
            }
            throw LoomNetworkGenerationChangedException(
              fromGeneration: attemptGeneration,
              toGeneration: LoomDefaultNetworkGeneration.current.generation,
            );
          }
          _failedUntil.remove(route.candidate.id);
          activeRouteId = route.candidate.id;
          state = route.candidate.kind == LoomRouteKind.localNetwork
              ? LoomConnectivityState.localNetwork
              : LoomConnectivityState.online;
          LoomTransportDiagnostics.event(
            'route_attempt_succeeded',
            sendAttemptId: sendAttemptId,
            networkGeneration: attemptGeneration,
            routeCategory: routeCategory,
          );
          return value;
        } on LoomNetworkGenerationChangedException catch (error) {
          lastError = error;
          generationChanged = true;
          _discardStaleLanRoutes(
            LoomDefaultNetworkGeneration.current.generation,
          );
          LoomTransportDiagnostics.event(
            'stale_attempt_cancelled',
            sendAttemptId: sendAttemptId,
            networkGeneration: LoomDefaultNetworkGeneration.current.generation,
            routeCategory: routeCategory,
            exceptionType: error.runtimeType.toString(),
          );
          break;
        } on LoomHttpStatusException catch (error) {
          lastError = error;
          if (!error.retryableOnAlternateRoute) {
            state = LoomConnectivityState.nodeUnreachable;
            rethrow;
          }
        } catch (error) {
          lastError = error;
          if (LoomDefaultNetworkGeneration.current.generation !=
              attemptGeneration) {
            generationChanged = true;
            _discardStaleLanRoutes(
              LoomDefaultNetworkGeneration.current.generation,
            );
            break;
          }
        }
        _failedUntil[route.candidate.id] = DateTime.now().add(
          failedRouteCooldown,
        );
      }

      if (generationChanged) {
        final remaining = _remaining(clock, budget);
        if (remaining != null && remaining == Duration.zero) {
          throw TimeoutException(
            'Loom online send attempt budget expired',
            budget,
          );
        }
        // A new generation gets only the budget left from the original Send;
        // it never receives a fresh deadline.
        continue;
      }
      state = LoomConnectivityState.nodeUnreachable;
      throw lastError ??
          const LoomMessagingTransportUnavailable(
            'No verified route to Home Node',
          );
    }
  }

  @override
  Future<List<LoomConversation>> fetchConversations() =>
      _try((api) => api.fetchConversations());

  @override
  Future<LoomSendReceipt> sendOpaqueMessage({
    required String conversationId,
    required String clientId,
    required LoomMessageType type,
    required String ciphertext,
    required String protocolVersion,
    String? replyToMessageId,
    Map<String, Object?> metadata = const {},
  }) =>
      _try(
        (api) => api.sendOpaqueMessage(
          conversationId: conversationId,
          clientId: clientId,
          type: type,
          ciphertext: ciphertext,
          protocolVersion: protocolVersion,
          replyToMessageId: replyToMessageId,
          metadata: metadata,
        ),
        budget: sendAttemptBudget,
        sendAttemptId: clientId,
      );

  @override
  Future<LoomSyncPage> sync({String? cursor, int limit = 200}) =>
      _try((api) => api.sync(cursor: cursor, limit: limit));

  @override
  Future<void> markRead({
    required String conversationId,
    required int throughOrder,
  }) =>
      _try(
        (api) => api.markRead(
          conversationId: conversationId,
          throughOrder: throughOrder,
        ),
      );

  @override
  Future<LoomAttachmentReceipt> uploadEncryptedAttachment({
    required String conversationId,
    required File encryptedFile,
    required String contentType,
  }) =>
      _try(
        (api) => api.uploadEncryptedAttachment(
          conversationId: conversationId,
          encryptedFile: encryptedFile,
          contentType: contentType,
        ),
        boundLanFallback: false,
      );
}
