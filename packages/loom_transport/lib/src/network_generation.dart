import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

/// Advisory description of the Android default-network generation.
///
/// Reachability is deliberately not represented here. [validated] and
/// [transportClass] are diagnostic hints only; Send must still prove success by
/// completing an actual bounded transport operation.
class LoomDefaultNetworkSnapshot {
  const LoomDefaultNetworkSnapshot({
    required this.generation,
    this.transportClass = 'unknown',
    this.validated,
  });

  final int generation;
  final String transportClass;
  final bool? validated;
}

/// Process-local monotonic generation used to invalidate work created on an
/// obsolete Android default network.
abstract final class LoomDefaultNetworkGeneration {
  static final StreamController<LoomDefaultNetworkSnapshot> _events =
      StreamController<LoomDefaultNetworkSnapshot>.broadcast(sync: true);

  static LoomDefaultNetworkSnapshot _current = const LoomDefaultNetworkSnapshot(
    generation: 0,
  );

  static LoomDefaultNetworkSnapshot get current => _current;
  static Stream<LoomDefaultNetworkSnapshot> get events => _events.stream;

  static LoomDefaultNetworkSnapshot advance({
    String transportClass = 'unknown',
    bool? validated,
  }) {
    final next = LoomDefaultNetworkSnapshot(
      generation: _current.generation + 1,
      transportClass: _safeTransportClass(transportClass),
      validated: validated,
    );
    _current = next;
    LoomTransportDiagnostics.event(
      'default_network_changed',
      networkGeneration: next.generation,
      transportCategory: next.transportClass,
    );
    _events.add(next);
    return next;
  }

  static String _safeTransportClass(String value) {
    final normalized = value.trim().toLowerCase();
    return switch (normalized) {
      'wifi' || 'cellular' || 'ethernet' || 'vpn' || 'none' => normalized,
      _ => 'unknown',
    };
  }
}

/// Transport operation was created on a default-network generation that is no
/// longer current. This remains a transport error and is DTN-fallback eligible.
class LoomNetworkGenerationChangedException extends SocketException {
  LoomNetworkGenerationChangedException({
    required this.fromGeneration,
    required this.toGeneration,
  }) : super(
         'Default network changed from generation '
         '$fromGeneration to $toGeneration',
       );

  final int fromGeneration;
  final int toGeneration;
}

/// Implemented by route clients that can actively tear down socket work.
abstract interface class LoomAbortableTransport {
  void abortActiveTransport(String category);
}

/// Low-volume, sanitized structured transport diagnostics.
///
/// Do not add message bodies, ciphertext, credentials, device secrets, keys,
/// signatures, SSIDs, IP addresses, or endpoint authorities here.
abstract final class LoomTransportDiagnostics {
  static void event(
    String phase, {
    String? sendAttemptId,
    int? networkGeneration,
    String? routeCategory,
    String? transportCategory,
    String? timeoutCategory,
    String? exceptionType,
    bool? fallback,
    String? serviceState,
    String? resultCategory,
  }) {
    final fields = <String, Object?>{
      'phase': phase,
      if (sendAttemptId != null) 'sendAttemptId': sendAttemptId,
      if (networkGeneration != null) 'networkGeneration': networkGeneration,
      if (routeCategory != null) 'routeCategory': routeCategory,
      if (transportCategory != null) 'transportCategory': transportCategory,
      if (timeoutCategory != null) 'timeoutCategory': timeoutCategory,
      if (exceptionType != null) 'exceptionType': exceptionType,
      if (fallback != null) 'fallback': fallback,
      if (serviceState != null) 'serviceState': serviceState,
      if (resultCategory != null) 'resultCategory': resultCategory,
    };
    developer.log(jsonEncode(fields), name: 'loom.transport');
  }
}
