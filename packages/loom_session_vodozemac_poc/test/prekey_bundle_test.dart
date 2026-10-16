import 'dart:convert';
import 'dart:typed_data';

import 'package:loom_session_vodozemac_poc/loom_session_vodozemac_poc.dart';
import 'package:test/test.dart';

void main() {
  test('v2 prekey bundle preserves fallback kind', () {
    const bundle = LoomVodozemacPocPrekeyBundle(
      identityKey: 'identity-key',
      oneTimeKey: 'fallback-key',
      keyKind: LoomVodozemacPocPrekeyKind.fallback,
    );
    final decoded = LoomVodozemacPocPrekeyBundle.decode(bundle.encode());
    expect(decoded.identityKey, 'identity-key');
    expect(decoded.oneTimeKey, 'fallback-key');
    expect(decoded.keyKind, LoomVodozemacPocPrekeyKind.fallback);
  });

  test('legacy v1 bundle decodes as one-time prekey', () {
    final bytes = Uint8List.fromList(
      utf8.encode(
        jsonEncode(<String, Object?>{
          'version': 1,
          'protocol': LoomVodozemacPocPrekeyBundle.protocol,
          'identityKey': 'identity-key',
          'oneTimeKey': 'legacy-key',
        }),
      ),
    );
    final decoded = LoomVodozemacPocPrekeyBundle.decode(bytes);
    expect(decoded.keyKind, LoomVodozemacPocPrekeyKind.oneTime);
    expect(decoded.oneTimeKey, 'legacy-key');
  });

  test('v2 bundle without a valid kind fails closed', () {
    final bytes = Uint8List.fromList(
      utf8.encode(
        jsonEncode(<String, Object?>{
          'version': 2,
          'protocol': LoomVodozemacPocPrekeyBundle.protocol,
          'keyKind': 'maybe',
          'identityKey': 'identity-key',
          'oneTimeKey': 'prekey',
        }),
      ),
    );
    expect(
      () => LoomVodozemacPocPrekeyBundle.decode(bytes),
      throwsFormatException,
    );
  });
}
