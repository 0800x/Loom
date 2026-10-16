import 'dart:async';
import 'dart:io';
import 'package:loom_next/features/media/application/voice_draft_controller.dart';
import 'package:loom_next/features/media/application/media_batch_controller.dart';
import 'package:loom_next/features/messaging/application/message_content.dart';

void check(bool condition, String reason) {
  if (!condition) throw StateError(reason);
}

class FakeRecorder implements VoiceRecorderBackend {
  Completer<bool>? permissionGate;
  Completer<void>? startGate;
  Completer<File?>? stopGate;
  final levels = StreamController<double>.broadcast();
  Directory? folder;
  File? file;
  int starts = 0, cancels = 0;
  bool allowed = true;
  @override
  Future<bool> permission() async =>
      permissionGate == null ? allowed : await permissionGate!.future;
  @override
  Future<void> start() async {
    starts++;
    if (startGate != null) await startGate!.future;
    folder = await Directory.systemTemp.createTemp('loom_voice_test_');
    file = await File('${folder!.path}/voice.m4a').writeAsBytes([1, 2, 3]);
  }

  @override
  Stream<double> get amplitudes => levels.stream;
  @override
  Future<File?> stop() async =>
      stopGate == null ? file : await stopGate!.future;
  @override
  Future<void> cancel() async {
    cancels++;
    if (folder?.existsSync() == true) await folder!.delete(recursive: true);
    folder = null;
  }

  @override
  Future<void> dispose() => levels.close();
}

Future<void> makeDraft(
  VoiceDraftController controller,
  FakeRecorder backend,
) async {
  await controller.start();
  backend.levels.add(.2);
  backend.levels.add(.8);
  await Future<void>.delayed(const Duration(milliseconds: 730));
  await controller.release();
  check(
    controller.phase == VoicePhase.draft,
    'release must create a review draft',
  );
  check(
    controller.waveform.length == 2 && controller.waveform.last == .8,
    'waveform must use captured levels',
  );
}

final Map<String, Future<void> Function()> mediaDraftScenarios = {
  'rapid start requests produce exactly one native recording': () async {
    final backend = FakeRecorder()..permissionGate = Completer<bool>();
    final controller = VoiceDraftController(backend);
    final first = controller.start();
    await controller.start();
    backend.permissionGate!.complete(true);
    await first;
    check(backend.starts == 1, 'repeated gestures started multiple recordings');
    await controller.cancel();
    controller.dispose();
  },
  'cancel during native stop cannot restore a late draft': () async {
    final backend = FakeRecorder();
    final controller = VoiceDraftController(backend);
    await controller.start();
    await Future<void>.delayed(const Duration(milliseconds: 730));
    backend.stopGate = Completer<File?>();
    final stop = controller.stop();
    await Future<void>.delayed(Duration.zero);
    final cancel = controller.cancel();
    backend.stopGate!.complete(backend.file);
    await Future.wait([stop, cancel]);
    check(
      controller.phase == VoicePhase.idle &&
          controller.file == null &&
          backend.folder == null,
      'late stop restored a cancelled recording',
    );
    controller.dispose();
  },
  'release before permission prevents native start': () async {
    final backend = FakeRecorder()..permissionGate = Completer<bool>();
    final controller = VoiceDraftController(backend);
    final start = controller.start();
    await Future<void>.delayed(Duration.zero);
    final release = controller.release();
    backend.permissionGate!.complete(true);
    await Future.wait([start, release]);
    check(
      backend.starts == 0 && controller.phase == VoicePhase.idle,
      'late permission started recording',
    );
    controller.dispose();
  },
  'cancel during native start cleans up only after start finishes': () async {
    final backend = FakeRecorder()..startGate = Completer<void>();
    final controller = VoiceDraftController(backend);
    final start = controller.start();
    await Future<void>.delayed(Duration.zero);
    final cancel = controller.cancel();
    check(backend.cancels == 0, 'cancel raced native start');
    backend.startGate!.complete();
    await Future.wait([start, cancel]);
    check(
      controller.phase == VoicePhase.idle && backend.folder == null,
      'cancel left a recording file',
    );
    controller.dispose();
  },
  'permission denied returns to idle without starting': () async {
    final backend = FakeRecorder()..allowed = false;
    final controller = VoiceDraftController(backend);
    await controller.start();
    check(
      backend.starts == 0 &&
          controller.error != null &&
          controller.phase == VoicePhase.idle,
      'permission denial mishandled',
    );
    controller.dispose();
  },
  'short recording is deleted rather than sent': () async {
    final backend = FakeRecorder();
    final controller = VoiceDraftController(backend);
    await controller.start();
    await controller.release();
    check(
      controller.phase == VoicePhase.idle &&
          controller.file == null &&
          backend.folder == null,
      'short clip retained',
    );
    controller.dispose();
  },
  'locked recording ignores release and waits for Stop': () async {
    final backend = FakeRecorder();
    final controller = VoiceDraftController(backend);
    await controller.start();
    controller.lock();
    await controller.release();
    check(
      controller.phase == VoicePhase.locked,
      'release stopped locked recording',
    );
    await controller.cancel();
    controller.dispose();
  },
  'failed upload retains the same draft for retry': () async {
    final backend = FakeRecorder();
    final controller = VoiceDraftController(backend);
    await makeDraft(controller, backend);
    final file = controller.file!;
    await controller.send((_, _, _) async => false);
    check(
      controller.phase == VoicePhase.draft &&
          controller.file == file &&
          file.existsSync(),
      'failed upload lost draft',
    );
    await controller.send((source, _, _) async {
      check(source == file, 'retry changed file');
      return true;
    });
    check(
      controller.phase == VoicePhase.idle && !file.existsSync(),
      'success did not release temporary file',
    );
    controller.dispose();
  },
  'disposal during upload leases file until upload completes': () async {
    final backend = FakeRecorder();
    final controller = VoiceDraftController(backend);
    await makeDraft(controller, backend);
    final file = controller.file!;
    final started = Completer<void>(), finish = Completer<bool>();
    final sending = controller.send((_, _, _) {
      started.complete();
      return finish.future;
    });
    await started.future;
    controller.dispose();
    check(file.existsSync(), 'disposal deleted file still used by uploader');
    finish.complete(true);
    await sending;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    check(!file.existsSync(), 'disposed upload leaked temporary file');
  },
  'batch retries remaining items without repeating success or caption':
      () async {
        final batch = MediaBatchController<String>();
        for (final id in ['a', 'b', 'c']) {
          batch.toggle(id, id);
        }
        final sent = <String>[], captions = <bool>[];
        await batch.send((item, caption) async {
          sent.add(item);
          captions.add(caption);
          return item != 'b';
        }, authorized: () => true);
        check(
          batch.pending.keys.join() == 'b',
          'partial success was not removed',
        );
        await batch.send((item, caption) async {
          sent.add(item);
          captions.add(caption);
          return true;
        }, authorized: () => true);
        check(
          sent.join() == 'abcb' &&
              captions.join(',') == 'true,false,false,false',
          'retry duplicated success/caption',
        );
        batch.dispose();
      },
  'batch selection limit and navigation guard': () async {
    final batch = MediaBatchController<String>(limit: 2);
    check(
      batch.toggle('a', 'a') &&
          batch.toggle('b', 'b') &&
          !batch.toggle('c', 'c'),
      'limit ignored',
    );
    var allowed = true;
    final sent = <String>[];
    await batch.send((item, _) async {
      sent.add(item);
      allowed = false;
      return true;
    }, authorized: () => allowed);
    check(
      sent.join() == 'a' && batch.pending.keys.join() == 'b',
      'sent next item after navigation/lock',
    );
    batch.dispose();
  },
  'encrypted reply excerpt and optional duration survive round trip': () async {
    const content = LoomMessageContent(
      text: 'پاسخ',
      reply: {
        'clientId': 'missing-original',
        'sender': '@peer:node',
        'text': 'متن اصلی',
      },
      attachment: {
        'kind': 'audio',
        'url': 'https://example.org/opaque',
        'key': 'opaque',
        'bytes': 3,
        'durationMs': 1200,
        'waveform': [.2, .8],
      },
    );
    final decoded = LoomMessageContent.decode(content.encode());
    check(
      decoded.reply?['text'] == 'متن اصلی' &&
          decoded.attachment?['durationMs'] == 1200,
      'authenticated metadata lost',
    );
    check(
      decoded.resolvedReplyExcerpt(null) == 'متن اصلی' &&
          decoded.resolvedReplyExcerpt('') == 'متن اصلی',
      'missing original hid authenticated excerpt',
    );
    check(
      const LoomMessageContent(attachment: {'kind': 'audio'}).replyExcerpt ==
          'Voice message',
      'media reply lacked meaningful excerpt',
    );
    check(
      LoomMessageContent.decode('legacy text').text == 'legacy text',
      'legacy text rejected',
    );
    var rejected = false;
    try {
      LoomMessageContent.decode(
        const LoomMessageContent(
          attachment: {
            'kind': 'audio',
            'url': 'https://example.org/opaque',
            'key': 'opaque',
            'bytes': 3,
            'durationMs': -1,
          },
        ).encode(),
      );
    } on FormatException {
      rejected = true;
    }
    check(rejected, 'invalid duration accepted');
  },
};
