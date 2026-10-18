import 'dart:async';
import 'dart:convert';

/// Nearby bearers are capabilities, not promises that every platform supports
/// each mechanism. Native adapters decide which are actually available.
enum LoomNearbyBearer {
  bluetoothLowEnergy,
  wifiDirect,
  wifiAware,
  multipeer,
  localPeer,
}

/// Privacy-preserving discovery beacon. It intentionally contains no username,
/// Loom address, Home Node, stable device ID, or public identity key.
class LoomNearbyAdvertisement {
  const LoomNearbyAdvertisement({
    required this.protocolVersion,
    required this.rendezvousId,
    required this.bearers,
    required this.expiresAt,
  });

  factory LoomNearbyAdvertisement.fromJson(Map<String, Object?> json) {
    final version = json['protocolVersion'];
    final rendezvousId = json['rendezvousId'];
    final rawBearers = json['bearers'];
    final expiresAtRaw = json['expiresAt'];
    if (version != 1 ||
        rendezvousId is! String ||
        rendezvousId.length < 16 ||
        rendezvousId.length > 128) {
      throw const FormatException('Invalid nearby advertisement');
    }
    if (rawBearers is! List ||
        rawBearers.isEmpty ||
        rawBearers.length > 8 ||
        rawBearers.any((value) => value is! String)) {
      throw const FormatException('Invalid nearby bearer list');
    }
    final expiresAt = expiresAtRaw is String
        ? DateTime.tryParse(expiresAtRaw)?.toUtc()
        : null;
    if (expiresAt == null)
      throw const FormatException('Invalid nearby advertisement expiry');
    final bearers = rawBearers
        .cast<String>()
        .map((name) => LoomNearbyBearer.values.byName(name))
        .toSet()
        .toList(growable: false);
    return LoomNearbyAdvertisement(
      protocolVersion: 1,
      rendezvousId: rendezvousId,
      bearers: bearers,
      expiresAt: expiresAt,
    );
  }

  final int protocolVersion;
  final String rendezvousId;
  final List<LoomNearbyBearer> bearers;
  final DateTime expiresAt;

  Map<String, Object?> toJson() => <String, Object?>{
        'protocolVersion': protocolVersion,
        'rendezvousId': rendezvousId,
        'bearers': bearers.map((value) => value.name).toList(growable: false),
        'expiresAt': expiresAt.toUtc().toIso8601String(),
      };
}

class LoomNearbyCandidate {
  const LoomNearbyCandidate({
    required this.advertisement,
    required this.bearer,
    required this.nativeHandle,
    this.signalStrength,
  });

  final LoomNearbyAdvertisement advertisement;
  final LoomNearbyBearer bearer;

  /// Opaque adapter-owned identifier. It must not be interpreted by app/UI
  /// code and must not contain secrets.
  final String nativeHandle;
  final int? signalStrength;
}

/// A bounded, ordered, bidirectional byte channel supplied by a native nearby
/// implementation. No production adapter is faked in the Dart foundation.
abstract interface class LoomNearbyLink {
  LoomNearbyBearer get bearer;
  Future<List<int>> receive({Duration timeout = const Duration(seconds: 30)});
  Future<void> send(List<int> bytes);
  Future<void> close();
}

abstract interface class LoomNearbyAdvertisingSession {
  Stream<LoomNearbyLink> get incomingLinks;
  Future<void> close();
}

abstract interface class LoomNearbyRadioAdapter {
  Set<LoomNearbyBearer> get supportedBearers;

  Stream<LoomNearbyCandidate> scan({
    Duration timeout = const Duration(seconds: 8),
  });

  Future<LoomNearbyAdvertisingSession> advertise(
    LoomNearbyAdvertisement advertisement,
  );

  Future<LoomNearbyLink> connect(LoomNearbyCandidate candidate);
}

/// Secure framing around a native nearby link. Cryptography is injected from
/// loom_crypto_bridge so transport does not own keys or primitive choices.
class LoomNearbySecureConnection {
  LoomNearbySecureConnection({
    required this.link,
    required Future<List<int>> Function(List<int>) seal,
    required Future<List<int>> Function(List<int>) open,
    this.maxPlaintextBytes = 256 * 1024,
    this.maxProtectedBytes = 320 * 1024,
  })  : _seal = seal,
        _open = open;

  final LoomNearbyLink link;
  final Future<List<int>> Function(List<int>) _seal;
  final Future<List<int>> Function(List<int>) _open;
  final int maxPlaintextBytes;
  final int maxProtectedBytes;

  Future<List<int>> receive({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final protectedBytes = await link.receive(timeout: timeout);
    if (protectedBytes.isEmpty || protectedBytes.length > maxProtectedBytes) {
      throw const FormatException('Nearby protected frame exceeds bounds');
    }
    final plaintext = await _open(protectedBytes);
    if (plaintext.length > maxPlaintextBytes) {
      throw const FormatException('Nearby plaintext frame exceeds bounds');
    }
    return plaintext;
  }

  Future<void> send(List<int> plaintext) async {
    if (plaintext.isEmpty || plaintext.length > maxPlaintextBytes) {
      throw ArgumentError.value(
        plaintext.length,
        'plaintext.length',
        'Nearby frame exceeds bounds',
      );
    }
    final protectedBytes = await _seal(plaintext);
    if (protectedBytes.isEmpty || protectedBytes.length > maxProtectedBytes) {
      throw StateError('Nearby protector produced an invalid frame size');
    }
    await link.send(protectedBytes);
  }

  Future<void> close() => link.close();
}

/// Length-prefixed JSON packet codec used *inside* the authenticated encrypted
/// nearby channel. It never handles plaintext message content; message payloads
/// remain opaque application ciphertext.
class LoomNearbyPacketCodec {
  const LoomNearbyPacketCodec();

  List<int> encode(Map<String, Object?> packet) {
    final body = utf8.encode(jsonEncode(packet));
    if (body.isEmpty || body.length > 256 * 1024) {
      throw const FormatException('Nearby packet exceeds maximum size');
    }
    return body;
  }

  Map<String, Object?> decode(List<int> bytes) {
    if (bytes.isEmpty || bytes.length > 256 * 1024) {
      throw const FormatException('Nearby packet exceeds maximum size');
    }
    final value = jsonDecode(utf8.decode(bytes));
    if (value is! Map<String, Object?>) {
      throw const FormatException('Nearby packet must be a JSON object');
    }
    return value;
  }
}
