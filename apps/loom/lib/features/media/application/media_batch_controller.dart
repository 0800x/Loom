import 'media_draft_notifier.dart';

/// Tracks only the unsent selection. Successful items are removed immediately,
/// so retries cannot resend the successful part of a batch.
class MediaBatchController<T> extends MediaDraftNotifier {
  MediaBatchController({this.limit = 10});
  final int limit;
  final Map<String, T> _pending = {};
  Map<String, T> get pending => Map.unmodifiable(_pending);
  bool sending = false;
  bool captionSent = false;
  int completed = 0, total = 0;
  String? error;
  bool _stopped = false, _disposed = false;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  bool toggle(String id, T item) {
    if (sending || _disposed) return false;
    if (_pending.containsKey(id)) {
      _pending.remove(id);
    } else {
      if (_pending.length >= limit) return false;
      _pending[id] = item;
    }
    error = null;
    _notify();
    return true;
  }

  void remove(String id) {
    if (!sending) {
      _pending.remove(id);
      _notify();
    }
  }

  Future<void> send(
    Future<bool> Function(T, bool withCaption) upload, {
    required bool Function() authorized,
  }) async {
    if (sending || _disposed || _pending.isEmpty || !authorized()) return;
    sending = true;
    _stopped = false;
    completed = 0;
    total = _pending.length;
    error = null;
    _notify();
    try {
      for (final entry in _pending.entries.toList()) {
        if (_stopped || _disposed || !authorized()) break;
        var ok = false;
        try {
          ok = await upload(entry.value, !captionSent);
        } catch (_) {}
        if (ok) {
          _pending.remove(entry.key);
          captionSent = true;
        } else {
          error = 'send_failed';
        }
        completed++;
        _notify();
      }
    } finally {
      sending = false;
      _notify();
    }
  }

  void stop() {
    _stopped = true;
  }

  @override
  void dispose() {
    _disposed = true;
    stop();
    super.dispose();
  }
}
