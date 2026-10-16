import 'dart:io';
import 'package:loom_next/features/messaging/application/encrypted_media.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

// Run on a device with microphone permission granted; this uses its real codec.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native AAC recording produces an encryptable authenticated file',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('Recorder integration'))),
      );
      final recorder = AudioRecorder();
      final temp = await getTemporaryDirectory();
      final folder = await Directory(
        '${temp.path}/loom_native_record_test',
      ).create(recursive: true);
      final file = File('${folder.path}/voice.m4a');
      try {
        expect(
          await recorder.hasPermission(),
          isTrue,
          reason: 'Grant microphone permission on the test device.',
        );
        await recorder.start(
          const RecordConfig(
            encoder: AudioEncoder.aacLc,
            bitRate: 64000,
            numChannels: 1,
          ),
          path: file.path,
        );
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        expect(await recorder.stop(), file.path);
        final clear = await file.readAsBytes();
        expect(clear.length, greaterThan(128));
        final sealed = await LoomEncryptedMedia.encrypt(clear);
        expect(sealed.bytes, isNot(orderedEquals(clear)));
        final received = await LoomEncryptedMedia.decrypt(
          sealed.bytes,
          sealed.key,
          clear.length,
        );
        expect(received, orderedEquals(clear));
        received.fillRange(0, received.length, 0);
        clear.fillRange(0, clear.length, 0);
      } finally {
        await recorder.dispose();
        await folder.delete(recursive: true);
      }
    },
  );
}
