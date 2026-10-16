import 'package:loom_models/loom_models.dart';
import 'package:test/test.dart';

void main() {
  test('ICE server serializes one URL compactly', () {
    const server = LoomIceServer(
      urls: ['turns:turn.example.org:5349'],
      username: 'u',
      credential: 'c',
    );
    expect(server.toJson()['urls'], 'turns:turn.example.org:5349');
  });
}
