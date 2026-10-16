import 'package:loom_crypto_bridge/loom_crypto_bridge.dart';
import 'package:loom_models/loom_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('stored session metadata round trips without tokens', () {
    final stored = LoomStoredSession(
      endpoint: Uri.parse('http://192.168.1.4:7483'),
      node: LoomNodeDescriptor(
        nodeId: 'node:home',
        name: 'Home Node',
        domain: '192.168.1.4:7483',
        operatorCountry: '—',
        networkLocation: 'LAN',
        registration: 'open',
        federation: false,
        protocols: const ['loom-federation-v1'],
        publicKey: 'public-key',
        fingerprint: 'AA BB CC',
        capabilities: const ['opaque-messaging'],
        lastVerified: DateTime.utc(2026, 9, 2),
      ),
      liveInfo: const LoomNodeLiveInfo(
        nodeId: 'node:home',
        serverVersion: '0.8.0',
        protocolVersion: 'loom-node-v1',
        registration: 'open',
        federationMode: 'disabled',
        capabilities: ['opaque-messaging'],
      ),
      receipt: const LoomRegistrationReceipt(
        accountId: 'account-1',
        deviceId: 'device-1',
        address: '@alice:192.168.1.4:7483',
        homeNode: '192.168.1.4:7483',
      ),
    );

    final decoded = LoomStoredSession.decode(stored.encode());
    expect(decoded.endpoint, stored.endpoint);
    expect(decoded.node.nodeId, stored.node.nodeId);
    expect(decoded.node.publicKey, stored.node.publicKey);
    expect(decoded.liveInfo.serverVersion, '0.8.0');
    expect(decoded.receipt.address, stored.receipt.address);
    expect(stored.encode(), isNot(contains('refreshToken')));
  });
}
