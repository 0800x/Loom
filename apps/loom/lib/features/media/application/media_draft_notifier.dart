typedef MediaDraftListener = void Function();

/// Platform-independent observation for the recording and upload state machines.
/// Native plugins and widgets are adapters; they do not own transition logic.
abstract class MediaDraftNotifier {
  final List<MediaDraftListener> _listeners = [];
  void addListener(MediaDraftListener listener) => _listeners.add(listener);
  void removeListener(MediaDraftListener listener) =>
      _listeners.remove(listener);
  void notifyListeners() {
    for (final listener in List<MediaDraftListener>.of(_listeners)) {
      if (_listeners.contains(listener)) listener();
    }
  }

  void dispose() => _listeners.clear();
}
