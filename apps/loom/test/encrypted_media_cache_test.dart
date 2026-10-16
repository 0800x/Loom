import 'dart:io';
import 'dart:async';
import 'dart:typed_data';

import 'package:loom_next/features/messaging/application/encrypted_media.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory temp;
  late Uint8List clear;
  late ({Uint8List bytes, String key}) sealed;
  late Map<String, Object?> media;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('loom_cache_test_');
    clear = Uint8List.fromList(List.generate(2048, (i) => i % 251));
    sealed = await LoomEncryptedMedia.encrypt(clear);
    media = {
      'url': 'https://home.example/api/v1/attachments/att_${'a' * 64}',
      'key': sealed.key,
      'bytes': clear.length,
      'kind': 'audio',
    };
  });
  tearDown(() async {
    await temp.delete(recursive: true);
  });
  Future<void> cache() => LoomEncryptedMedia.cacheEncrypted(
    media,
    sealed.bytes,
    'home.example',
    temporaryDirectory: () async => temp,
  );

  test(
    'large encrypted media stays responsive and rejects tampering',
    () async {
      final bytes = Uint8List.fromList(
        List.generate(2 * 1024 * 1024, (i) => i % 251),
      );
      var ticks = 0;
      final clock = Timer.periodic(
        const Duration(milliseconds: 1),
        (_) => ticks++,
      );
      try {
        final encrypted = await LoomEncryptedMedia.encrypt(bytes);
        ticks = 0;
        final decoded = await LoomEncryptedMedia.decrypt(
          encrypted.bytes,
          encrypted.key,
          bytes.length,
        );
        expect(decoded, bytes);
        expect(
          ticks,
          greaterThan(0),
          reason: 'UI isolate services events while crypto runs',
        );
        encrypted.bytes[30] ^= 1;
        await expectLater(
          LoomEncryptedMedia.decrypt(
            encrypted.bytes,
            encrypted.key,
            bytes.length,
          ),
          throwsA(isA<Exception>()),
        );
      } finally {
        clock.cancel();
      }
    },
  );
  test(
    'local outgoing media decrypts from ciphertext without an HTTP client',
    () async {
      await cache();
      await HttpOverrides.runZoned<Future<void>>(() async {
        final result = await LoomEncryptedMedia.download(
          media,
          'home.example',
          temporaryDirectory: () async => temp,
        );
        expect(result, clear);
      }, createHttpClient: (_) => throw StateError('Network must not be used'));
      final files = await Directory(
        '${temp.path}/loom_media_encrypted',
      ).list().toList();
      expect(files, hasLength(1));
      expect(await (files.single as File).readAsBytes(), sealed.bytes);
    },
  );
  test('cached media still rejects a different sender Home Node', () async {
    await cache();
    await expectLater(
      LoomEncryptedMedia.readCached(
        media,
        'attacker.example',
        temporaryDirectory: () async => temp,
      ),
      throwsFormatException,
    );
  });
  test('tampered ciphertext is removed and can be fetched again', () async {
    await cache();
    final file =
        (await Directory('${temp.path}/loom_media_encrypted').list().first)
            as File;
    final damaged = Uint8List.fromList(sealed.bytes);
    damaged[damaged.length - 1] ^= 1;
    await file.writeAsBytes(damaged);
    expect(
      await LoomEncryptedMedia.readCached(
        media,
        'home.example',
        temporaryDirectory: () async => temp,
      ),
      isNull,
    );
    expect(await file.exists(), isFalse);
  });
  test('wrong capability cannot decrypt a cached object', () async {
    await cache();
    final other = await LoomEncryptedMedia.encrypt(clear);
    expect(
      await LoomEncryptedMedia.readCached(
        {...media, 'key': other.key},
        'home.example',
        temporaryDirectory: () async => temp,
      ),
      isNull,
    );
  });
  test('cancelled local reads do not return decrypted bytes', () async {
    await cache();
    await expectLater(
      LoomEncryptedMedia.download(
        media,
        'home.example',
        cancelled: () => true,
        temporaryDirectory: () async => temp,
      ),
      throwsStateError,
    );
  });
  test('missing cache does not invent local media', () async {
    expect(
      await LoomEncryptedMedia.readCached(
        media,
        'home.example',
        temporaryDirectory: () async => temp,
      ),
      isNull,
    );
  });
}
