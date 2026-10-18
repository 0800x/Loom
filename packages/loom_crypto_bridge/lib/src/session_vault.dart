import 'app_lock.dart';

import 'dart:convert';

import 'package:loom_models/loom_models.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class LoomStoredSession {
  const LoomStoredSession({
    required this.endpoint,
    required this.node,
    required this.liveInfo,
    required this.receipt,
  });

  final Uri endpoint;
  final LoomNodeDescriptor node;
  final LoomNodeLiveInfo liveInfo;
  final LoomRegistrationReceipt receipt;

  String encode() => jsonEncode({
        'schemaVersion': 1,
        'endpoint': endpoint.toString(),
        'node': {
          'nodeId': node.nodeId,
          'name': node.name,
          'domain': node.domain,
          'operatorCountry': node.operatorCountry,
          'networkLocation': node.networkLocation,
          'registration': node.registration,
          'federation': node.federation,
          'protocols': node.protocols,
          'publicKey': node.publicKey,
          'fingerprint': node.fingerprint,
          'capabilities': node.capabilities,
          'region': node.region,
          'operatorName': node.operatorName,
          'lastVerified': node.lastVerified?.toIso8601String(),
        },
        'liveInfo': {
          'nodeId': liveInfo.nodeId,
          'serverVersion': liveInfo.serverVersion,
          'protocolVersion': liveInfo.protocolVersion,
          'registration': liveInfo.registration,
          'federationMode': liveInfo.federationMode,
          'capabilities': liveInfo.capabilities,
          'capacityUsed': liveInfo.capacityUsed,
          'capacityLimit': liveInfo.capacityLimit,
          'maxMediaBytes': liveInfo.maxMediaBytes,
        },
        'receipt': {
          'accountId': receipt.accountId,
          'deviceId': receipt.deviceId,
          'address': receipt.address,
          'homeNode': receipt.homeNode,
        },
      });

  factory LoomStoredSession.decode(String value) {
    final decoded = jsonDecode(value);
    if (decoded is! Map<String, Object?> || decoded['schemaVersion'] != 1) {
      throw const FormatException('Unsupported stored session');
    }
    Map<String, Object?> object(String key) {
      final item = decoded[key];
      if (item is! Map<String, Object?>) {
        throw FormatException('Invalid stored session $key');
      }
      return item;
    }

    String requiredString(Map<String, Object?> source, String key) {
      final item = source[key];
      if (item is! String || item.trim().isEmpty) {
        throw FormatException('Invalid stored session $key');
      }
      return item.trim();
    }

    List<String> strings(Map<String, Object?> source, String key) {
      final item = source[key];
      if (item is! List || item.any((entry) => entry is! String)) {
        throw FormatException('Invalid stored session $key');
      }
      return item.cast<String>().toList(growable: false);
    }

    final endpoint = Uri.tryParse(requiredString(decoded, 'endpoint'));
    if (endpoint == null ||
        endpoint.host.isEmpty ||
        (endpoint.scheme != 'https' && endpoint.scheme != 'http')) {
      throw const FormatException('Invalid stored session endpoint');
    }
    final nodeJson = object('node');
    final liveJson = object('liveInfo');
    final receiptJson = object('receipt');
    final lastVerified = nodeJson['lastVerified'];
    return LoomStoredSession(
      endpoint: endpoint,
      node: LoomNodeDescriptor(
        nodeId: requiredString(nodeJson, 'nodeId'),
        name: requiredString(nodeJson, 'name'),
        domain: requiredString(nodeJson, 'domain'),
        operatorCountry: requiredString(nodeJson, 'operatorCountry'),
        networkLocation: requiredString(nodeJson, 'networkLocation'),
        registration: requiredString(nodeJson, 'registration'),
        federation: nodeJson['federation'] == true,
        protocols: strings(nodeJson, 'protocols'),
        publicKey: requiredString(nodeJson, 'publicKey'),
        fingerprint: requiredString(nodeJson, 'fingerprint'),
        capabilities: strings(nodeJson, 'capabilities'),
        region: nodeJson['region'] as String?,
        operatorName: nodeJson['operatorName'] as String?,
        lastVerified: lastVerified is String
            ? DateTime.tryParse(lastVerified)?.toUtc()
            : null,
      ),
      liveInfo: LoomNodeLiveInfo(
        nodeId: requiredString(liveJson, 'nodeId'),
        serverVersion: requiredString(liveJson, 'serverVersion'),
        protocolVersion: requiredString(liveJson, 'protocolVersion'),
        registration: requiredString(liveJson, 'registration'),
        federationMode: requiredString(liveJson, 'federationMode'),
        capabilities: strings(liveJson, 'capabilities'),
        capacityUsed: liveJson['capacityUsed'] as int?,
        capacityLimit: liveJson['capacityLimit'] as int?,
        maxMediaBytes: liveJson['maxMediaBytes'] as int?,
      ),
      receipt: LoomRegistrationReceipt(
        accountId: requiredString(receiptJson, 'accountId'),
        deviceId: requiredString(receiptJson, 'deviceId'),
        address: requiredString(receiptJson, 'address'),
        homeNode: requiredString(receiptJson, 'homeNode'),
      ),
    );
  }
}

abstract interface class LoomSessionVault {
  Future<void> write(LoomStoredSession session);
  Future<LoomStoredSession?> read();
  Future<void> clear();
}

class LoomSecureSessionVault implements LoomSessionVault {
  LoomSecureSessionVault({FlutterSecureStorage? storage})
      : _storage = LoomSecretStorage(storage);

  static const _key = 'loom.session.metadata.v1';
  final LoomSecretStorage _storage;

  @override
  Future<void> write(LoomStoredSession session) =>
      _storage.write(key: _key, value: session.encode());

  @override
  Future<LoomStoredSession?> read() async {
    final value = await _storage.read(key: _key);
    return value == null ? null : LoomStoredSession.decode(value);
  }

  @override
  Future<void> clear() => _storage.delete(key: _key);
}
