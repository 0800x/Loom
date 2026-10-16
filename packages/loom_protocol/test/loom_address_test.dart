import 'package:loom_protocol/loom_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('bare username resolves on the current Home Node', () {
    final address = LoomAddress.normalizeInput(
      'Alice',
      homeNode: 'node-a.example',
    );
    expect(address.username, 'alice');
    expect(address.homeNode, 'node-a.example');
    expect(address.canonical, '@alice:node-a.example');
    expect(address.isSameNode('NODE-A.EXAMPLE'), isTrue);
  });

  test('user-facing username@node alias becomes canonical address', () {
    final address = LoomAddress.normalizeInput(
      'alice@node-b.example',
      homeNode: 'node-a.example',
    );
    expect(address.canonical, '@alice:node-b.example');
    expect(address.isSameNode('node-a.example'), isFalse);
  });

  test('canonical address preserves Home Node port for LAN Nodes', () {
    final address = LoomAddress.normalizeInput(
      '@alice:192.168.1.4:7483',
      homeNode: '192.168.1.10:7483',
    );
    expect(address.homeNode, '192.168.1.4:7483');
    expect(address.canonical, '@alice:192.168.1.4:7483');
  });

  test('Home Node URL input is reduced to authority', () {
    final address = LoomAddress.normalizeInput(
      'alice',
      homeNode: 'https://node-a.example/',
    );
    expect(address.canonical, '@alice:node-a.example');
  });

  test('invalid address is rejected', () {
    expect(
      () => LoomAddress.normalizeInput(
        'a@node.example/path',
        homeNode: 'node.example',
      ),
      throwsFormatException,
    );
  });
}
