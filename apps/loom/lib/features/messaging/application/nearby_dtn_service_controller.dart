import 'dart:async';

import 'package:loom_crypto_bridge/loom_crypto_bridge.dart';
import 'package:loom_models/loom_models.dart';
import 'package:loom_protocol/loom_protocol.dart';
import 'package:loom_storage/loom_storage.dart';
import 'package:loom_transport/loom_transport.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import '../../onboarding/application/onboarding_controller.dart';
import 'authorized_device_direct_transport_signer.dart';
import 'legacy_dtn_custody.dart';
import 'legacy_dtn_delivery_intake.dart';
import 'legacy_dtn_local_recipient.dart';
import 'nearby_legacy_delivery_intake.dart';
import 'v2_messaging_runtime.dart';

enum LoomNearbyDtnServiceStatus {
  off,
  starting,
  active,
  stopping,
  unsupported,
  permissionDenied,
  error,
}

abstract interface class LoomNearbyDtnRuntimePort {
  LoomNearbyDtnEncounterCoordinator get coordinator;
  Future<Set<LoomNearbyBearer>> supportedBearers();
  Future<bool> requestPermissionsFor(Set<LoomNearbyBearer> bearers);
  Future<void> startForegroundMode(LoomNearbyBearer bearer);
  Future<void> stopForegroundMode();
  LoomNearbyRadioAdapter radioFor(LoomNearbyBearer bearer);
  void kickDestinationNodeUplink(LoomDirectTransportSigner signer);
  void close();
}

abstract interface class LoomNearbyRecipientProbeRuntime {
  set recipientProbeAcceptor(LoomNearbyRecipientProbeAcceptor? value);
}

typedef LoomNearbyDtnRuntimeFactory =
    LoomNearbyDtnRuntimePort Function(String applicationSupportPath);
typedef LoomNearbyDtnSignerFactory =
    Future<LoomDirectTransportSigner> Function(
      String identityId,
      String deviceId,
    );
typedef LoomNearbyDtnRoundExecutor =
    Future<LoomNearbyDtnRoundResult> Function({
      required LoomNearbyDtnRuntimePort runtime,
      required LoomDirectTransportSigner signer,
      required LoomNearbyBearer bearer,
    });
typedef LoomNearbyMessageGatewayRoundExecutor =
    Future<int> Function({
      required LoomNearbyDtnRuntimePort runtime,
      required LoomDirectTransportSigner signer,
      required LoomNearbyBearer bearer,
      required LoomNearbyLegacyMessageGateway gateway,
    });
typedef LoomNearbyLocalInboxChanged = Future<void> Function();

/// Product lifecycle owner for user-enabled Nearby DTN mode.
///
/// Internet availability never disables this controller: an online phone is
/// still a Nearby carrier/gateway and must continue scan/advertise/custody.
final class LoomNearbyDtnServiceController extends ChangeNotifier
    with WidgetsBindingObserver {
  LoomNearbyDtnServiceController({
    required this.onboarding,
    LoomNearbyDtnRuntimeFactory? runtimeFactory,
    LoomNearbyDtnSignerFactory? signerFactory,
    LoomNearbyDtnRoundExecutor? roundExecutor,
    LoomNearbyMessageGatewayRoundExecutor? messageGatewayRoundExecutor,
    LoomNearbyLegacyMessageGateway? messageGateway,
    Future<String> Function()? supportPathProvider,
    this.onLocalInboxChanged,
    this.roundPause = const Duration(seconds: 3),
  }) : _runtimeFactory = runtimeFactory ?? _defaultRuntimeFactory,
       _signerFactory = signerFactory ?? _defaultSignerFactory,
       _roundExecutor = roundExecutor ?? _defaultRoundExecutor,
       _messageGatewayRoundExecutor =
           messageGatewayRoundExecutor ?? _defaultMessageGatewayRoundExecutor,
       _messageGateway = messageGateway ?? LoomNearbyLegacyMessageGateway(),
       _supportPathProvider = supportPathProvider ?? _defaultSupportPath {
    _networkSubscription = LoomDefaultNetworkGeneration.events.listen(
      _onDefaultNetworkGenerationChanged,
    );
  }

  final LoomOnboardingController onboarding;
  final LoomNearbyDtnRuntimeFactory _runtimeFactory;
  final LoomNearbyDtnSignerFactory _signerFactory;
  final LoomNearbyDtnRoundExecutor _roundExecutor;
  final LoomNearbyMessageGatewayRoundExecutor _messageGatewayRoundExecutor;
  final LoomNearbyLegacyMessageGateway _messageGateway;
  final Future<String> Function() _supportPathProvider;
  final Duration roundPause;

  LoomNearbyLocalInboxChanged? onLocalInboxChanged;
  bool Function(String clientId)? canConfirmLegacyDelivery;

  LoomNearbyDtnServiceStatus status = LoomNearbyDtnServiceStatus.off;
  Set<LoomNearbyBearer> supportedBearers = const <LoomNearbyBearer>{};
  LoomNearbyBearer? foregroundBearer;
  LoomNearbyDtnRoundResult? lastRound;
  LoomProximityGatewayRoundResult? lastProximityRound;
  String? errorMessage;

  LoomNearbyDtnRuntimePort? _runtime;
  LoomDirectTransportSigner? _signer;
  Future<void>? _loopFuture;
  Future<void> _radioTail = Future<void>.value();
  Completer<void>? _roundWake;
  StreamSubscription<LoomDefaultNetworkSnapshot>? _networkSubscription;
  bool _priorityRoundRequested = false;
  bool _enabled = false;
  bool _disposed = false;
  bool _observingLifecycle = false;
  bool _transientRecoveryInFlight = false;
  int _lifecycleGeneration = 0;

  bool get enabled => _enabled;

  static bool shouldAutoRecover(LoomNearbyDtnServiceStatus value) =>
      value == LoomNearbyDtnServiceStatus.error;

  bool _isCurrentLifecycle(int generation) =>
      !_disposed && generation == _lifecycleGeneration;

  Future<bool> enable() async {
    if (_disposed) return false;
    if (_enabled) return true;
    if (status == LoomNearbyDtnServiceStatus.starting ||
        status == LoomNearbyDtnServiceStatus.stopping) {
      return false;
    }
    final identity = onboarding.committedIdentity;
    final receipt = onboarding.receipt;
    if (identity == null || receipt == null) {
      _fail('A registered Loom device is required for Nearby DTN mode.');
      return false;
    }

    final lifecycleGeneration = ++_lifecycleGeneration;
    _startObservingLifecycle();
    status = LoomNearbyDtnServiceStatus.starting;
    errorMessage = null;
    notifyListeners();
    LoomNearbyDtnRuntimePort? runtime;
    try {
      final supportPath = await _supportPathProvider();
      if (!_isCurrentLifecycle(lifecycleGeneration)) return false;
      runtime = _runtime;
      if (runtime == null) {
        final created = _runtimeFactory(supportPath);
        if (!_isCurrentLifecycle(lifecycleGeneration)) {
          created.close();
          return false;
        }
        _runtime = created;
        runtime = created;
      }

      final hardwareSupported = await runtime.supportedBearers();
      if (!_isCurrentLifecycle(lifecycleGeneration)) return false;
      if (hardwareSupported.isEmpty) {
        supportedBearers = const <LoomNearbyBearer>{};
        status = LoomNearbyDtnServiceStatus.unsupported;
        errorMessage = 'No native Nearby bearer is supported on this device.';
        notifyListeners();
        _stopObservingLifecycle();
        _closeRuntimeIf(runtime);
        return false;
      }

      final usable = <LoomNearbyBearer>{};
      Object? lastPermissionError;
      for (final bearer in _orderedBearers(hardwareSupported)) {
        try {
          final allowed = await runtime.requestPermissionsFor(
            <LoomNearbyBearer>{bearer},
          );
          if (!_isCurrentLifecycle(lifecycleGeneration)) return false;
          if (allowed) usable.add(bearer);
        } catch (error) {
          if (!_isCurrentLifecycle(lifecycleGeneration)) return false;
          lastPermissionError = error;
        }
      }
      if (!_isCurrentLifecycle(lifecycleGeneration)) return false;
      supportedBearers = Set<LoomNearbyBearer>.unmodifiable(usable);
      if (usable.isEmpty) {
        status = LoomNearbyDtnServiceStatus.permissionDenied;
        errorMessage =
            lastPermissionError == null
                ? 'No Nearby bearer was authorized and ready.'
                : 'No Nearby bearer could be authorized: ${_safeError(lastPermissionError)}';
        notifyListeners();
        _stopObservingLifecycle();
        _closeRuntimeIf(runtime);
        return false;
      }

      LoomNearbyBearer? foreground;
      Object? lastForegroundError;
      for (final bearer in _orderedBearers(usable)) {
        try {
          await runtime.startForegroundMode(bearer);
          if (!_isCurrentLifecycle(lifecycleGeneration)) {
            try {
              await runtime.stopForegroundMode();
            } catch (_) {}
            return false;
          }
          foreground = bearer;
          break;
        } catch (error) {
          if (!_isCurrentLifecycle(lifecycleGeneration)) return false;
          lastForegroundError = error;
        }
      }
      if (foreground == null) {
        throw lastForegroundError ??
            StateError(
              'No authorized Nearby bearer could start foreground mode',
            );
      }

      final signer = await _signerFactory(
        identity.identityId,
        receipt.deviceId,
      );
      if (!_isCurrentLifecycle(lifecycleGeneration)) {
        try {
          await runtime.stopForegroundMode();
        } catch (_) {}
        return false;
      }
      _signer = signer;
      // Capture a stable non-null port across asynchronous inbox callbacks.
      final LoomNearbyDtnRuntimePort activeRuntime = runtime;
      if (activeRuntime is LoomNearbyRecipientProbeRuntime) {
        (activeRuntime as LoomNearbyRecipientProbeRuntime)
            .recipientProbeAcceptor = _acceptRecipientProbe;
        activeRuntime.coordinator.onInboxChanged = () async {
          await _consumeLocalRecipientPackets();
          if (_enabled && _isCurrentLifecycle(lifecycleGeneration)) {
            activeRuntime.kickDestinationNodeUplink(signer);
          }
        };
        activeRuntime.coordinator.onPacketForwarded = (packet) {
          if (!_enabled || !_isCurrentLifecycle(lifecycleGeneration)) return;
          final clientId = packet.messageId;
          if (clientId != null) unawaited(_recordNearbySend(clientId));
        };
      }
      foregroundBearer = foreground;
      _enabled = true;
      try {
        await _consumeLocalRecipientPackets();
      } catch (_) {
        // Durable custody remains in place and a later round can retry.
      }
      if (!_isCurrentLifecycle(lifecycleGeneration) || !_enabled) return false;
      runtime.kickDestinationNodeUplink(signer);
      status = LoomNearbyDtnServiceStatus.active;
      errorMessage = null;
      notifyListeners();
      if (!_isCurrentLifecycle(lifecycleGeneration)) return false;
      _loopFuture = _runLoop(runtime, signer, lifecycleGeneration);
      return true;
    } catch (error) {
      if (!_isCurrentLifecycle(lifecycleGeneration)) return false;
      _signer = null;
      try {
        await runtime?.stopForegroundMode();
      } catch (_) {}
      if (!_isCurrentLifecycle(lifecycleGeneration)) return false;
      _enabled = false;
      foregroundBearer = null;
      _fail(_safeError(error));
      if (runtime != null) _closeRuntimeIf(runtime);
      return false;
    }
  }

  Future<void> disable() async {
    if (_disposed && _runtime == null) return;
    final lifecycleGeneration = ++_lifecycleGeneration;
    _enabled = false;
    _wakeLoop();
    _stopObservingLifecycle();
    _signer = null;
    status = LoomNearbyDtnServiceStatus.stopping;
    notifyListeners();
    final runtime = _runtime;
    final loop = _loopFuture;
    try {
      await runtime?.stopForegroundMode();
      await loop;
      await _radioTail.catchError((Object _) {});
    } catch (_) {
      // Shutdown remains best-effort; runtime closure below is authoritative.
    } finally {
      if (lifecycleGeneration == _lifecycleGeneration) {
        _loopFuture = null;
        foregroundBearer = null;
        if (runtime != null) _closeRuntimeIf(runtime);
        if (!_disposed) {
          status = LoomNearbyDtnServiceStatus.off;
          errorMessage = null;
          notifyListeners();
        }
      }
    }
  }

  Future<void> persistOpaqueMessageForDtn({
    required String destinationNodeDomain,
    required String senderAddress,
    required List<LoomDeviceKeyBundle> recipientDevices,
    required String conversationId,
    required String clientId,
    required LoomMessageType type,
    required String ciphertext,
    required String protocolVersion,
    String? replyToMessageId,
    DateTime? createdAt,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) async {
    if (_disposed) throw StateError('Nearby DTN service is disposed');
    final receipt = onboarding.receipt;
    if (receipt == null ||
        receipt.address.toLowerCase() != senderAddress.toLowerCase()) {
      throw StateError('DTN sender identity is unavailable or mismatched');
    }
    final supportPath = await _supportPathProvider();
    await const LoomLegacyDtnCustodyWriter().persist(
      applicationSupportPath: supportPath,
      destinationNodeDomain: destinationNodeDomain,
      senderAddress: senderAddress,
      conversationId: conversationId,
      clientId: clientId,
      type: type,
      ciphertext: ciphertext,
      protocolVersion: protocolVersion,
      recipientDevices: recipientDevices,
      replyToMessageId: replyToMessageId,
      metadata: metadata,
      createdAt: createdAt,
    );
    LoomTransportDiagnostics.event(
      'dtn_custody_persisted',
      sendAttemptId: clientId,
      networkGeneration: LoomDefaultNetworkGeneration.current.generation,
      fallback: true,
      serviceState: status.name,
    );

    _priorityRoundRequested = true;
    _wakeLoop();

    final runtime = _runtime;
    final signer = _signer;
    if (runtime != null && signer != null) {
      runtime.kickDestinationNodeUplink(signer);
    } else {
      _requestTransientRecovery();
    }
  }

  Future<LoomSendReceipt> sendOpaqueMessageViaInternetGateway({
    required String conversationId,
    required String clientId,
    required LoomMessageType type,
    required String ciphertext,
    required String protocolVersion,
    String? replyToMessageId,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) async {
    final runtime = _runtime;
    final signer = _signer;
    final identity = onboarding.committedIdentity;
    final receipt = onboarding.receipt;
    final lifecycleGeneration = _lifecycleGeneration;
    if (!_enabled ||
        _disposed ||
        runtime == null ||
        signer == null ||
        identity == null ||
        receipt == null) {
      throw StateError('Nearby messaging mode is not enabled');
    }

    Object? lastError;
    final ordered = _orderedBearers(supportedBearers);
    for (final bearer in ordered) {
      if (!_isCurrentLifecycle(lifecycleGeneration) || !_enabled) {
        throw StateError('Nearby messaging mode stopped during send');
      }
      try {
        return await _withRadio(() async {
          if (!_isCurrentLifecycle(lifecycleGeneration) ||
              !_enabled ||
              !identical(_runtime, runtime)) {
            throw StateError('Nearby messaging mode is no longer active');
          }
          return _messageGateway.sendViaRadio(
            radio: runtime.radioFor(bearer),
            bearer: bearer,
            signer: signer,
            homeNodeDomain: receipt.homeNode,
            accountId: receipt.accountId,
            identityId: identity.identityId,
            deviceId: receipt.deviceId,
            senderAddress: receipt.address,
            conversationId: conversationId,
            clientId: clientId,
            type: type,
            ciphertext: ciphertext,
            protocolVersion: protocolVersion,
            replyToMessageId: replyToMessageId,
            metadata: metadata,
            scanTimeout: const Duration(seconds: 12),
          );
        }, lifecycleGeneration: lifecycleGeneration);
      } catch (error) {
        lastError = error;
      }
    }
    throw lastError ?? StateError('No usable Nearby Internet gateway found');
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || _disposed) return;
    if (!_enabled) {
      _requestTransientRecovery();
      return;
    }
    _wakeOnlineWork('app_resumed');
  }

  void _onDefaultNetworkGenerationChanged(
    LoomDefaultNetworkSnapshot snapshot,
  ) {
    if (_disposed) return;
    LoomTransportDiagnostics.event(
      'nearby_network_generation_observed',
      networkGeneration: snapshot.generation,
      transportCategory: snapshot.transportClass,
      serviceState: status.name,
    );
    // Connectivity is advisory. Never disable scan/advertise/custody here.
    if (_enabled) _wakeOnlineWork('network_generation');
  }

  void _wakeOnlineWork(String category) {
    final runtime = _runtime;
    final signer = _signer;
    if (runtime == null || signer == null || !_enabled || _disposed) return;
    _priorityRoundRequested = true;
    _wakeLoop();
    runtime.kickDestinationNodeUplink(signer);
    LoomTransportDiagnostics.event(
      'destination_uplink_kicked',
      networkGeneration: LoomDefaultNetworkGeneration.current.generation,
      serviceState: status.name,
      resultCategory: category,
    );
  }

  void _requestTransientRecovery() {
    if (_disposed ||
        _enabled ||
        _transientRecoveryInFlight ||
        !shouldAutoRecover(status) ||
        onboarding.committedIdentity == null ||
        onboarding.receipt == null) {
      return;
    }
    final recoveryGeneration = _lifecycleGeneration;
    _transientRecoveryInFlight = true;
    unawaited(
      enable().whenComplete(() {
        if (_disposed) return;
        if (_lifecycleGeneration >= recoveryGeneration) {
          _transientRecoveryInFlight = false;
        }
      }),
    );
  }

  Future<void> _runLoop(
    LoomNearbyDtnRuntimePort runtime,
    LoomDirectTransportSigner signer,
    int lifecycleGeneration,
  ) async {
    final ordered = _orderedBearers(supportedBearers);
    var maintenanceIndex = 0;
    while (_enabled && _isCurrentLifecycle(lifecycleGeneration)) {
      _priorityRoundRequested = false;
      for (final bearer in ordered) {
        if (!_enabled || !_isCurrentLifecycle(lifecycleGeneration)) return;
        try {
          final round = await _withRadio(
            () => _roundExecutor(
              runtime: runtime,
              signer: signer,
              bearer: bearer,
            ),
            lifecycleGeneration: lifecycleGeneration,
          );
          if (!_isCurrentLifecycle(lifecycleGeneration)) return;
          lastRound = round;
          status = LoomNearbyDtnServiceStatus.active;
          errorMessage = null;
          notifyListeners();
        } catch (error) {
          if (!_isCurrentLifecycle(lifecycleGeneration)) return;
          status = LoomNearbyDtnServiceStatus.active;
          errorMessage = _safeError(error);
          notifyListeners();
        } finally {
          if (_enabled && _isCurrentLifecycle(lifecycleGeneration)) {
            // Retry intake even after an interrupted encounter. The packet store
            // is the source of truth, not the volatile round counters.
            try {
              await _consumeLocalRecipientPackets();
            } catch (_) {}
            runtime.kickDestinationNodeUplink(signer);
          }
        }
      }

      if (!_enabled || !_isCurrentLifecycle(lifecycleGeneration)) return;
      if (!_priorityRoundRequested) {
        // Give DTN another turn between maintenance protocols. Cycling every
        // protocol on every bearer first used to starve chat for tens of seconds.
        final maintenance =
            ordered.isEmpty
                ? <LoomNearbyBearer>[]
                : [ordered[(maintenanceIndex ~/ 2) % ordered.length]];
        final runMessageGateway = maintenanceIndex++ % 2 == 0;
        for (final bearer in maintenance) {
          if (!_enabled ||
              !_isCurrentLifecycle(lifecycleGeneration) ||
              _priorityRoundRequested) {
            break;
          }
          try {
            if (runMessageGateway) {
              await _withRadio(
                () => _messageGatewayRoundExecutor(
                  runtime: runtime,
                  signer: signer,
                  bearer: bearer,
                  gateway: _messageGateway,
                ),
                lifecycleGeneration: lifecycleGeneration,
              );
            } else if (_enabled &&
                _isCurrentLifecycle(lifecycleGeneration) &&
                !_priorityRoundRequested) {
              await _withRadio(
                () => _runProximityGatewayRound(
                  runtime: runtime,
                  signer: signer,
                  bearer: bearer,
                  lifecycleGeneration: lifecycleGeneration,
                ),
                lifecycleGeneration: lifecycleGeneration,
              );
            }
            if (!_isCurrentLifecycle(lifecycleGeneration)) return;
            status = LoomNearbyDtnServiceStatus.active;
            errorMessage = null;
            notifyListeners();
          } catch (error) {
            if (!_isCurrentLifecycle(lifecycleGeneration)) return;
            status = LoomNearbyDtnServiceStatus.active;
            errorMessage = _safeError(error);
            notifyListeners();
          } finally {
            if (_enabled && _isCurrentLifecycle(lifecycleGeneration)) {
              runtime.kickDestinationNodeUplink(signer);
            }
          }
        }
      }

      if (!_enabled || !_isCurrentLifecycle(lifecycleGeneration)) return;
      if (_priorityRoundRequested) continue;
      await _waitForNextRound();
    }
  }

  Future<bool> _acceptRecipientProbe(Uint8List bytes) async {
    final identity = onboarding.committedIdentity;
    final receipt = onboarding.receipt;
    if (!_enabled || _disposed || identity == null || receipt == null) {
      return false;
    }
    final outer = LoomEnvelopeV2Codec.decodeOuter(bytes);
    if (!outer.expiresAtBucket.isAfter(DateTime.now().toUtc())) return false;
    final accepted = await LoomLegacyDtnDeliveryIntake.acceptEnvelope(
      applicationSupportPath: await _supportPathProvider(),
      ownAddress: receipt.address,
      identityId: identity.identityId,
      deviceId: receipt.deviceId,
      deviceSecurity: LoomDeviceSecurityCoreV1(),
      expectedPacketId: outer.packetId,
      expectedMailboxToken: outer.routingHint.mailboxToken,
      exactOuterEnvelopeBytes: bytes,
      fallbackCreatedAt: DateTime.now().toUtc(),
    );
    if (accepted && !_disposed) {
      final callback = onLocalInboxChanged;
      if (callback != null) unawaited(callback().catchError((Object _) {}));
    }
    // Intake may also queue/verify a separate signed end-recipient receipt.
    // This boolean hop response itself is never sender-visible delivery proof.
    return accepted;
  }

  Future<void> _recordNearbySend(String clientId) async {
    try {
      final path = await _supportPathProvider();
      if (_disposed) return;
      final store = LoomMessagingStore.openFile(
        '$path/loom-messages-v1.sqlite3',
      );
      try {
        store.recordTransportPath(
          clientId,
          LoomMessageTransportPath.nearby,
          mergeRoutes: true,
        );
        // A committed hop has left this device. It is not final-recipient
        // delivery proof; keep the Internet retry and stronger receipt states.
        store.updateDeliveryByClientId(clientId, LoomDeliveryState.sent);
      } finally {
        store.close();
      }
      await onLocalInboxChanged?.call();
    } catch (_) {
      /* Routing UI must never turn a committed hop into a failure. */
    }
  }

  Future<int>? _intakeFuture;
  bool _intakeRequested = false;
  Future<int> _consumeLocalRecipientPackets() {
    _intakeRequested = true;
    return _intakeFuture ??= _drainRecipientPackets().whenComplete(
      () => _intakeFuture = null,
    );
  }

  Future<int> _drainRecipientPackets() async {
    var total = 0;
    do {
      _intakeRequested = false;
      total += await _consumeRecipientPacketsOnce();
    } while (_intakeRequested && !_disposed);
    return total;
  }

  Future<int> _consumeRecipientPacketsOnce() async {
    final identity = onboarding.committedIdentity;
    final receipt = onboarding.receipt;
    if (identity == null || receipt == null) return 0;
    final accepted = const LoomLegacyDtnLocalRecipientSweeper().consume(
      applicationSupportPath: await _supportPathProvider(),
      ownAddress: receipt.address,
      identityId: identity.identityId,
      deviceId: receipt.deviceId,
      deviceSecurity: LoomDeviceSecurityCoreV1(),
    );
    final count = await accepted;
    if (count > 0) {
      final callback = onLocalInboxChanged;
      if (callback != null) {
        try {
          await callback();
        } catch (_) {}
      }
    }
    return count;
  }

  Future<void> _runProximityGatewayRound({
    required LoomNearbyDtnRuntimePort runtime,
    required LoomDirectTransportSigner signer,
    required LoomNearbyBearer bearer,
    required int lifecycleGeneration,
  }) async {
    final identity = onboarding.committedIdentity;
    final receipt = onboarding.receipt;
    final node = onboarding.nodes.selectedNode;
    if (identity == null || receipt == null || node == null) return;
    final supportPath = await _supportPathProvider();
    if (!_isCurrentLifecycle(lifecycleGeneration)) return;
    final round = await LoomProximityGatewayRoundRunner().run(
      radio: runtime.radioFor(bearer),
      bearer: bearer,
      signer: signer,
      recipientIdentityId: identity.identityId,
      recipientDeviceId: receipt.deviceId,
      recipientNodeId: node.nodeId,
      recipientNodeDomain: receipt.homeNode,
      acceptLegacyDelivery: (delivery) async {
        final accepted = await LoomNearbyLegacyDeliveryIntake.acceptOnce(
          applicationSupportPath: supportPath,
          ownAddress: receipt.address,
          delivery: delivery,
        );
        if (!accepted) return false;
        final callback = onLocalInboxChanged;
        if (callback != null) await callback();
        final clientId = delivery.event.payload['clientId'];
        // The signed recipient receipt means the message is readable. A relay
        // custody ACK alone must not light up the sender's second tick.
        return clientId is String &&
            canConfirmLegacyDelivery?.call(clientId) == true;
      },
      acceptV2Packet:
          (packet) => LoomLegacyDtnDeliveryIntake.acceptGatewayPacket(
            applicationSupportPath: supportPath,
            ownAddress: receipt.address,
            identityId: identity.identityId,
            deviceId: receipt.deviceId,
            deviceSecurity: LoomDeviceSecurityCoreV1(),
            packet: packet,
          ),
      scanTimeout: const Duration(seconds: 3),
      advertisementLifetime: const Duration(seconds: 12),
      maxCandidates: 4,
      claimLimit: 20,
    );
    if (_isCurrentLifecycle(lifecycleGeneration)) {
      lastProximityRound = round;
      // Gateway intake writes the legacy inbox directly, outside the DTN sweep.
      final callback = onLocalInboxChanged;
      if (callback != null) await callback();
    }
  }

  Future<T> _withRadio<T>(
    Future<T> Function() action, {
    int? lifecycleGeneration,
  }) async {
    final previous = _radioTail;
    final release = Completer<void>();
    _radioTail = release.future;
    try {
      try {
        await previous;
      } catch (_) {}
      if (lifecycleGeneration != null &&
          !_isCurrentLifecycle(lifecycleGeneration)) {
        throw StateError('Stale Nearby lifecycle generation');
      }
      final value = await action();
      if (lifecycleGeneration != null &&
          !_isCurrentLifecycle(lifecycleGeneration)) {
        throw StateError('Stale Nearby lifecycle generation');
      }
      return value;
    } finally {
      if (!release.isCompleted) release.complete();
    }
  }

  Future<void> _waitForNextRound() async {
    if (roundPause <= Duration.zero) {
      await Future<void>.delayed(Duration.zero);
      return;
    }
    final wake = Completer<void>();
    _roundWake = wake;
    try {
      await Future.any<void>(<Future<void>>[
        Future<void>.delayed(roundPause),
        wake.future,
      ]);
    } finally {
      if (identical(_roundWake, wake)) _roundWake = null;
    }
  }

  void _wakeLoop() {
    final wake = _roundWake;
    if (wake != null && !wake.isCompleted) wake.complete();
  }

  void _startObservingLifecycle() {
    if (_observingLifecycle || _disposed) return;
    WidgetsBinding.instance.addObserver(this);
    _observingLifecycle = true;
  }

  void _stopObservingLifecycle() {
    if (!_observingLifecycle) return;
    WidgetsBinding.instance.removeObserver(this);
    _observingLifecycle = false;
  }

  void _closeRuntimeIf(LoomNearbyDtnRuntimePort runtime) {
    if (!identical(_runtime, runtime)) return;
    _runtime = null;
    runtime.close();
  }

  void _fail(String message) {
    status = LoomNearbyDtnServiceStatus.error;
    errorMessage = message;
    if (!_disposed) notifyListeners();
  }

  static List<LoomNearbyBearer> _orderedBearers(
    Set<LoomNearbyBearer> values,
  ) => const <LoomNearbyBearer>[
    LoomNearbyBearer.bluetoothLowEnergy,
    LoomNearbyBearer.wifiAware,
    LoomNearbyBearer.wifiDirect,
  ].where(values.contains).toList(growable: false);

  static String _safeError(Object error) {
    final text = error.toString().replaceAll(RegExp(r'[\r\n]+'), ' ');
    return text.length <= 240 ? text : text.substring(0, 240);
  }

  static Future<String> _defaultSupportPath() async =>
      (await getApplicationSupportDirectory()).path;

  static LoomNearbyDtnRuntimePort _defaultRuntimeFactory(String path) =>
      _V2NearbyDtnRuntimePort(
        LoomV2MessagingRuntime.open(applicationSupportPath: path),
      );

  static Future<LoomDirectTransportSigner> _defaultSignerFactory(
    String identityId,
    String deviceId,
  ) async => LoomAuthorizedDeviceDirectTransportSigner(
    deviceSecurity: LoomDeviceSecurityCoreV1(),
    identityId: identityId,
    deviceId: deviceId,
  );

  static Future<LoomNearbyDtnRoundResult> _defaultRoundExecutor({
    required LoomNearbyDtnRuntimePort runtime,
    required LoomDirectTransportSigner signer,
    required LoomNearbyBearer bearer,
  }) => LoomNearbyDtnRoundRunner(
    coordinator: runtime.coordinator,
    signer: signer,
  ).run(
    radio: runtime.radioFor(bearer),
    bearer: bearer,
    allowStoreCarry: true,
    scanTimeout: const Duration(seconds: 3),
    advertisementLifetime: const Duration(seconds: 12),
    maxCandidates: 4,
    maxPacketsPerLink: 8,
  );

  static Future<int> _defaultMessageGatewayRoundExecutor({
    required LoomNearbyDtnRuntimePort runtime,
    required LoomDirectTransportSigner signer,
    required LoomNearbyBearer bearer,
    required LoomNearbyLegacyMessageGateway gateway,
  }) => LoomNearbyLegacyMessageGatewayRoundRunner(gateway: gateway).run(
    radio: runtime.radioFor(bearer),
    bearer: bearer,
    signer: signer,
    lifetime: const Duration(seconds: 4),
    maxConcurrentLinks: 4,
  );

  @override
  void dispose() {
    if (_disposed) return;
    ++_lifecycleGeneration;
    _disposed = true;
    _enabled = false;
    _wakeLoop();
    _stopObservingLifecycle();
    unawaited(_networkSubscription?.cancel());
    _networkSubscription = null;
    onLocalInboxChanged = null;
    _signer = null;
    final runtime = _runtime;
    final loop = _loopFuture;
    if (runtime != null) {
      unawaited(runtime.stopForegroundMode().catchError((_) {}));
      if (loop == null) {
        _closeRuntimeIf(runtime);
      } else {
        unawaited(
          loop.whenComplete(() {
            if (identical(_runtime, runtime)) _closeRuntimeIf(runtime);
          }),
        );
      }
    }
    super.dispose();
  }
}

final class _V2NearbyDtnRuntimePort
    implements LoomNearbyDtnRuntimePort, LoomNearbyRecipientProbeRuntime {
  _V2NearbyDtnRuntimePort(this.runtime);

  final LoomV2MessagingRuntime runtime;

  @override
  set recipientProbeAcceptor(LoomNearbyRecipientProbeAcceptor? value) {
    runtime.nearbyDtnEncounters.recipientProbeAcceptor = value;
  }

  @override
  LoomNearbyDtnEncounterCoordinator get coordinator =>
      runtime.nearbyDtnEncounters;

  @override
  Future<Set<LoomNearbyBearer>> supportedBearers() =>
      runtime.supportedNearbyBearers();

  @override
  Future<bool> requestPermissionsFor(Set<LoomNearbyBearer> bearers) =>
      runtime.nearbyRadios.requestPermissionsFor(bearers);

  @override
  Future<void> startForegroundMode(LoomNearbyBearer bearer) =>
      runtime.nearbyRadios.startForegroundMode(bearer);

  @override
  Future<void> stopForegroundMode() =>
      runtime.nearbyRadios.stopForegroundMode();

  @override
  LoomNearbyRadioAdapter radioFor(LoomNearbyBearer bearer) =>
      runtime.nearbyRadioFor(bearer);

  @override
  void kickDestinationNodeUplink(LoomDirectTransportSigner signer) =>
      runtime.kickDestinationNodeUplink(signer);

  @override
  void close() => runtime.close();
}
