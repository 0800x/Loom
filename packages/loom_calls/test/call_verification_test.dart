import 'package:flutter_test/flutter_test.dart';
import 'package:loom_calls/loom_calls.dart';

void main() {
  test('derive produces stable four digits and three emoji', () async {
    final a = await LoomCallVerification.derive([1, 2, 3, 4]);
    final b = await LoomCallVerification.derive([1, 2, 3, 4]);
    expect(a.digits, b.digits);
    expect(a.emoji, b.emoji);
    expect(a.digits, hasLength(4));
    expect(a.digits, matches(RegExp(r'^\d{4}$')));
    expect(a.emoji, hasLength(3));
    final different = await LoomCallVerification.derive([9, 9, 9, 9]);
    expect(different.digits == a.digits && different.emoji == a.emoji, isFalse);
  });

  test('DTLS fingerprint derivation is order-independent and symmetric', () async {
    const localSdp = 'v=0\r\n'
        'a=fingerprint:sha-256 AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99'
        ':AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99\r\n';
    const remoteSdp = 'v=0\r\n'
        'a=fingerprint:sha-256 11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00'
        ':11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00\r\n';
    final caller = await LoomCallVerification.fromDtlsFingerprints(
      localSdp: localSdp,
      remoteSdp: remoteSdp,
    );
    final callee = await LoomCallVerification.fromDtlsFingerprints(
      localSdp: remoteSdp,
      remoteSdp: localSdp,
    );
    expect(caller, isNotNull);
    expect(callee, isNotNull);
    expect(caller!.digits, callee!.digits);
    expect(caller.emoji, callee.emoji);
    // A different remote certificate yields a different code.
    const tamperedSdp = 'v=0\r\n'
        'a=fingerprint:sha-256 FF:FF:FF:FF:FF:FF:FF:FF:FF:FF:FF:FF:FF:FF:FF:FF'
        ':FF:FF:FF:FF:FF:FF:FF:FF:FF:FF:FF:FF:FF:FF:FF:FF\r\n';
    final mitm = await LoomCallVerification.fromDtlsFingerprints(
      localSdp: localSdp,
      remoteSdp: tamperedSdp,
    );
    expect(mitm!.digits == caller.digits, isFalse);
  });

  test('DTLS derivation returns null before fingerprints exist', () async {
    expect(
      await LoomCallVerification.fromDtlsFingerprints(
        localSdp: null,
        remoteSdp: null,
      ),
      isNull,
    );
    expect(
      await LoomCallVerification.fromDtlsFingerprints(
        localSdp: 'v=0\r\n',
        remoteSdp: 'v=0\r\n',
      ),
      isNull,
    );
  });

  test('group call key derivation is bound to the call id', () async {
    final a = await LoomCallVerification.fromGroupCallKey(
      '11111111-1111-1111-1111-111111111111',
      List.filled(32, 7),
    );
    final b = await LoomCallVerification.fromGroupCallKey(
      '22222222-2222-2222-2222-222222222222',
      List.filled(32, 7),
    );
    expect(a.digits == b.digits && a.emoji == b.emoji, isFalse);
  });
}
