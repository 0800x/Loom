import 'package:loom_transport/loom_transport.dart';
import 'package:test/test.dart';

void main() {
  test('verified LAN route to the same Home Node is preferred', () {
    const policy = LoomRoutePolicy();
    final result = policy.select([
      LoomRouteCandidate(
        id: 'home',
        kind: LoomRouteKind.homeNode,
        nodeId: 'node:home',
        endpoint: Uri.parse('https://home.example'),
        identityVerified: true,
        latency: const Duration(milliseconds: 80),
      ),
      LoomRouteCandidate(
        id: 'lan',
        kind: LoomRouteKind.localNetwork,
        nodeId: 'node:home',
        endpoint: Uri.parse('https://home.example'),
        identityVerified: true,
        latency: const Duration(milliseconds: 5),
      ),
    ], homeNodeId: 'node:home');
    expect(result.ordered.first.id, 'lan');
    expect(result.state, LoomConnectivityState.localNetwork);
  });

  test('unverified or wrong-node LAN candidates are rejected', () {
    const policy = LoomRoutePolicy();
    final result = policy.select([
      LoomRouteCandidate(
        id: 'wrong',
        kind: LoomRouteKind.localNetwork,
        nodeId: 'node:other',
        endpoint: Uri.parse('https://other.example'),
        identityVerified: true,
      ),
      LoomRouteCandidate(
        id: 'unverified',
        kind: LoomRouteKind.localNetwork,
        nodeId: 'node:home',
        endpoint: Uri.parse('https://home.example'),
        identityVerified: false,
      ),
    ], homeNodeId: 'node:home');
    expect(result.ordered, isEmpty);
    expect(result.state, LoomConnectivityState.nodeUnreachable);
  });

  test('identity-verified private LAN endpoints are eligible', () {
    const policy = LoomRoutePolicy();
    final result = policy.select([
      LoomRouteCandidate(
        id: 'lan-http',
        kind: LoomRouteKind.localNetwork,
        nodeId: 'node:home',
        endpoint: Uri.parse('http://192.168.1.4:7483'),
        identityVerified: true,
      ),
    ], homeNodeId: 'node:home');
    expect(result.ordered.single.id, 'lan-http');
    expect(result.state, LoomConnectivityState.localNetwork);
  });

  test('plaintext public endpoints remain ineligible', () {
    const policy = LoomRoutePolicy();
    final result = policy.select([
      LoomRouteCandidate(
        id: 'public-http',
        kind: LoomRouteKind.homeNode,
        nodeId: 'node:home',
        endpoint: Uri.parse('http://example.org:7483'),
        identityVerified: true,
      ),
    ], homeNodeId: 'node:home');
    expect(result.ordered, isEmpty);
  });
}
