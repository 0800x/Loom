import 'dart:async';
import 'dart:io';

import 'media_draft_notifier.dart';

enum VoicePhase { idle, starting, recording, locked, stopping, draft, sending }

/// The backend owns ONLY its private temporary recording folder.
abstract interface class VoiceRecorderBackend {
  Future<bool> permission();
  Future<void> start();
  Stream<double> get amplitudes;
  Future<File?> stop();
  Future<void> cancel();
  Future<void> dispose();
}

/// Serializes native operations and invalidates late permission/start callbacks.
/// Sending leases the file until the uploader has finished, even on disposal.
class VoiceDraftController extends MediaDraftNotifier {
  VoiceDraftController(
    this.backend, {
    this.maxDuration = const Duration(minutes: 5),
  });
  final Duration maxDuration;
  bool _lockRequested = false;
  final VoiceRecorderBackend backend;
  VoicePhase phase = VoicePhase.idle;
  File? file;
  String? error;
  Duration duration = Duration.zero;
  final List<double> _peaks = [];
  StreamSubscription<double>? _amplitudes;
  Timer? _timer;
  final _clock = Stopwatch();
  Future<void> _tail = Future<void>.value();
  int _epoch = 0;
  bool _disposed = false;
  bool get active => phase != VoicePhase.idle;
  bool get capturing =>
      phase == VoicePhase.recording || phase == VoicePhase.locked;
  List<double> get waveform {
    if (_peaks.length <= 64) return List.unmodifiable(_peaks);
    // Preserve actual peaks from each time bucket, never synthesize bars.
    return List.generate(64, (i) {
      final start = i * _peaks.length ~/ 64;
      final end = (i + 1) * _peaks.length ~/ 64;
      return _peaks.sublist(start, end).reduce((a, b) => a > b ? a : b);
    });
  }

  bool _valid(int epoch) => !_disposed && epoch == _epoch;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> _enqueue(Future<void> Function() operation) {
    return _tail = _tail.catchError((Object _) {}).then((_) => operation());
  }

  Future<void> start({bool locked = false}) {
    if (_disposed || active) return Future.value();
    final epoch = ++_epoch;
    _lockRequested = locked;
    phase = VoicePhase.starting;
    error = null;
    duration = Duration.zero;
    _peaks.clear();
    _notify();
    return _enqueue(() async {
      try {
        final permitted = await backend.permission();
        if (!_valid(epoch)) return;
        if (!permitted) throw StateError('permission_denied');
        await backend.start();
        if (!_valid(epoch)) {
          await backend.cancel();
          return;
        }
        phase = _lockRequested ? VoicePhase.locked : VoicePhase.recording;
        _clock
          ..reset()
          ..start();
        _amplitudes = backend.amplitudes.listen(
          (level) {
            if (!_valid(epoch) || !capturing || !level.isFinite) return;
            if (_peaks.length < 2500) {
              _peaks.add(level.clamp(0.0, 1.0).toDouble());
            }
            _notify();
          },
          onError: (Object _) {
            unawaited(cancel());
          },
        );
        _timer = Timer.periodic(const Duration(milliseconds: 200), (_) {
          if (!_valid(epoch) || !capturing) return;
          duration = _clock.elapsed;
          _notify();
          if (duration >= maxDuration) unawaited(stop());
        });
        _notify();
      } catch (_) {
        await backend.cancel();
        if (_valid(epoch)) {
          phase = VoicePhase.idle;
          error = 'microphone_unavailable';
          _notify();
        }
      }
    });
  }

  void lock() {
    if (phase == VoicePhase.starting) {
      _lockRequested = true;
      return;
    }
    if (phase != VoicePhase.recording) return;
    phase = VoicePhase.locked;
    _notify();
  }

  Future<void> release() {
    if (phase == VoicePhase.starting) {
      return _lockRequested ? Future.value() : cancel();
    }
    if (phase == VoicePhase.recording) return stop();
    return Future.value();
  }

  Future<void> stop() {
    if (!capturing || _disposed) return Future.value();
    final epoch = _epoch;
    phase = VoicePhase.stopping;
    _clock.stop();
    duration = _clock.elapsed;
    _timer?.cancel();
    _notify();
    return _enqueue(() async {
      try {
        await _amplitudes?.cancel();
        _amplitudes = null;
        final recorded = await backend.stop();
        if (!_valid(epoch)) return; // queued cancel owns cleanup
        final length = recorded == null ? 0 : await recorded.length();
        if (!_valid(epoch)) return;
        if (recorded == null ||
            duration < const Duration(milliseconds: 700) ||
            length == 0) {
          await backend.cancel();
          if (!_valid(epoch)) return;
          phase = VoicePhase.idle;
          error = 'recording_too_short';
        } else {
          file = recorded;
          phase = VoicePhase.draft;
        }
      } catch (_) {
        await backend.cancel();
        if (!_valid(epoch)) return;
        phase = VoicePhase.idle;
        error = 'recording_failed';
      }
      _notify();
    });
  }

  Future<void> send(
    Future<bool> Function(File, List<double>, Duration) upload,
  ) {
    final draft = file;
    if (_disposed || phase != VoicePhase.draft || draft == null) {
      return Future.value();
    }
    final epoch = _epoch;
    final peaks = waveform;
    final elapsed = duration;
    phase = VoicePhase.sending;
    error = null;
    _notify();
    return _enqueue(() async {
      if (!_valid(epoch)) return;
      var ok = false;
      try {
        ok = await upload(draft, peaks, elapsed);
      } catch (_) {}
      if (!_valid(epoch)) return; // cancel/dispose queued AFTER this upload
      if (ok) {
        await backend.cancel();
        if (!_valid(epoch)) return;
        file = null;
        phase = VoicePhase.idle;
      } else {
        phase = VoicePhase.draft;
        error = 'send_failed';
      }
      _notify();
    });
  }

  Future<void> cancel() {
    ++_epoch;
    _timer?.cancel();
    _clock.stop();
    // Prevent restarting before native cleanup is complete.
    phase = VoicePhase.stopping;
    file = null;
    _notify();
    return _enqueue(() async {
      await _amplitudes?.cancel();
      _amplitudes = null;
      try {
        await backend.cancel();
      } catch (_) {}
      phase = VoicePhase.idle;
      _notify();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(cancel().then((_) => backend.dispose()));
    super.dispose();
  }
}
