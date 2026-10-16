import 'package:flutter/foundation.dart';

/// Per-player gain. Never writes to the operating system's master volume.
class LoomPlaybackVolume extends ChangeNotifier {
  double _value = 100;
  double _restore = 100;
  double get value => _value;
  bool get muted => _value == 0;
  Object? error;
  Future<void> Function(double)? _apply;
  Future<void> _tail = Future.value();

  Future<void> attach(Future<void> Function(double) apply) {
    _apply = apply;
    return _write();
  }

  void detach() => _apply = null;

  Future<void> set(double value) {
    if (!value.isFinite) throw ArgumentError.value(value, 'volume');
    _value = value.clamp(0.0, 100.0);
    if (_value > 0) _restore = _value;
    error = null;
    notifyListeners();
    return _write();
  }

  Future<void> toggleMute() => set(muted ? _restore : 0);

  Future<void> _write() {
    final apply = _apply;
    return _tail = _tail.then((_) async {
      if (apply == null || !identical(apply, _apply)) return;
      try {
        // Coalesce slider changes while the preceding native call is pending.
        await apply(_value);
        error = null;
      } catch (failure) {
        error = failure;
      }
      notifyListeners();
    });
  }
}
