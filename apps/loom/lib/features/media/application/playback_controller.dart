import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'music_queue.dart';
import 'media_audio_route.dart';
import 'playback_volume.dart';
import 'music_system_publisher.dart';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:flutter/foundation.dart';

import 'package:loom_crypto_bridge/loom_crypto_bridge.dart';
import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';

/// Separate music and voice sessions, independent of recycled chat rows/routes.
/// A private copy keeps the session alive when a decrypted chat row is disposed.
class LoomPlaybackController extends ChangeNotifier
    with WidgetsBindingObserver {
  LoomPlaybackController._({this._voiceSession = false}) {
    WidgetsBinding.instance.addObserver(this);
    LoomAppLock.instance.addListener(_lockChanged);
  }
  static int _focusEpoch = 0;
  static final instance = LoomPlaybackController._();
  static final voice = LoomPlaybackController._(voiceSession: true);
  final bool _voiceSession;
  final volume = LoomPlaybackVolume();
  final ValueNotifier<Duration> timeline = ValueNotifier(Duration.zero);
  Duration get position => timeline.value;
  set position(Duration value) => timeline.value = value;
  Duration _lastSystemPosition = Duration.zero;
  LoomMusicSystemPublisher? _systemPublisher;

  static Future<void> pauseAll() async {
    ++_focusEpoch;
    await instance.pause();
    await voice.pause();
  }

  static Future<void> closeAll() async {
    await instance.close();
    await voice.close();
  }

  Future<void> Function()? _activeVideo;
  bool Function()? blockedByCall;
  bool get _blocked =>
      LoomAppLock.instance.locked ||
      ((_voiceSession ? instance.blockedByCall : blockedByCall)?.call() ??
          false);
  Future<bool> claimVideo(Future<void> Function() pauseVideo) async {
    ++_focusEpoch;
    final previous = _activeVideo;
    _activeVideo = pauseVideo;
    try {
      await _player?.pause();
      await voice.pause();
      if (previous != null && previous != pauseVideo) await previous();
      return _activeVideo == pauseVideo && !_blocked;
    } catch (_) {
      releaseVideo(pauseVideo);
      rethrow;
    }
  }

  void releaseVideo(Future<void> Function() pauseVideo) {
    if (_activeVideo == pauseVideo) _activeVideo = null;
  }

  static Future<(String?, String?, Uint8List?)> inspectMusic(File file) =>
      compute(_musicTags, file.path);

  /// Probe the actual container/decoder without starting audible playback.
  /// Recorder wall time and a nonempty file alone do not prove a playable clip.
  static Future<Duration> inspectDuration(File file) async {
    MediaKit.ensureInitialized();
    final player = Player();
    final result = Completer<Duration>();
    final durationSub = player.stream.duration.listen((value) {
      if (value > Duration.zero && !result.isCompleted) result.complete(value);
    });
    final errorSub = player.stream.error.listen((_) {
      if (!result.isCompleted) {
        result.completeError(StateError('Invalid media'));
      }
    });
    try {
      final results = await Future.wait<dynamic>([
        player.open(Media(file.path), play: false),
        result.future.timeout(const Duration(seconds: 8)),
      ]);
      return results.last as Duration;
    } finally {
      await durationSub.cancel();
      await errorSub.cancel();
      await player.dispose();
    }
  }

  bool music = false;
  bool expanded = false;
  void setExpanded(bool value) {
    expanded = value;
    notifyListeners();
  }

  File? artwork;
  final List<LoomMusicTrack> _library = [];
  final LoomMusicQueue _queue = LoomMusicQueue();
  Map<String, List<String>> playlists = {};
  String? _playlistKey;
  Future<void>? _playlistLoad;
  int _libraryEpoch = 0;
  bool get shuffle => _queue.shuffle;
  int get repeat => _queue.repeat;
  _SystemAudioHandler? _handler;
  AudioSession? _session;
  Future<void>? _systemSetup;
  final List<StreamSubscription<dynamic>> _sessionSubscriptions = [];
  List<LoomMusicTrack> get queue =>
      List.unmodifiable(_queue.ids.map(track).whereType<LoomMusicTrack>());
  LoomMusicTrack? track(String id) {
    for (final value in _library) {
      if (value.id == id) return value;
    }
    return null;
  }

  final Map<String, Future<LoomMusicTrack?>> _registrations = {};
  Future<void> _registrationOperations = Future.value();

  Future<LoomMusicTrack?> registerMusic(
    File file,
    String id,
    String title,
    String subtitle,
  ) {
    final existing = track(id);
    if (existing != null) return Future.value(existing);
    if (_voiceSession) return Future.value(null);
    return _registrations.putIfAbsent(id, () {
      final generation = _libraryEpoch;
      final result = _registrationOperations.then<LoomMusicTrack?>((_) async {
        if (generation != _libraryEpoch || LoomAppLock.instance.locked) {
          return null;
        }
        try {
          return await _registerMusic(file, id, title, subtitle);
        } catch (_) {
          return null;
        }
      });
      _registrationOperations = result.then<void>((_) {});
      unawaited(
        result.then<void>((_) {
          _registrations.remove(id);
        }),
      );
      return result;
    });
  }

  Future<LoomMusicTrack?> _registerMusic(
    File file,
    String id,
    String title,
    String subtitle,
  ) async {
    final existing = track(id);
    if (existing != null) return existing;
    final generation = _libraryEpoch;
    if (LoomAppLock.instance.locked ||
        await file.length() > 128 * 1024 * 1024) {
      return null;
    }
    final temp = await getTemporaryDirectory();
    final root = await Directory(
      '${temp.path}/loom_music_library',
    ).create(recursive: true);
    final folder = await root.createTemp('track_');
    try {
      final copy = await file.copy('${folder.path}/track.m4a');
      final tags = await compute(_musicTags, copy.path);
      File? cover;
      final bytes = tags.$3;
      if (bytes != null) {
        cover = File('${folder.path}/cover');
        await cover.writeAsBytes(bytes, flush: true);
      }
      if (generation != _libraryEpoch || LoomAppLock.instance.locked) {
        await folder.delete(recursive: true);
        return null;
      }
      final raced = track(id);
      if (raced != null) {
        await folder.delete(recursive: true);
        return raced;
      }
      final result = LoomMusicTrack(
        id,
        copy,
        tags.$1 ?? title,
        tags.$2 ?? subtitle,
        cover,
        await copy.length(),
      );
      _library.add(result);
      // Bound decrypted cache. The active session has a separate private copy.
      while (_library.fold<int>(0, (sum, item) => sum + item.bytes) >
          256 * 1024 * 1024) {
        final victim = _library.firstWhere(
          (item) => item.id != sourceId,
          orElse: () => _library.first,
        );
        _library.remove(victim);
        _queue.remove(victim.id);
        await victim.file.parent.delete(recursive: true);
      }
      try {
        await _loadPlaylists();
      } catch (_) {}
      if (generation != _libraryEpoch || LoomAppLock.instance.locked) {
        return null;
      }
      notifyListeners();
      return result;
    } catch (_) {
      try {
        await folder.delete(recursive: true);
      } catch (_) {}
      return null;
    }
  }

  Future<void> _loadPlaylists() async {
    if (_playlistKey != null) return;
    try {
      await (_playlistLoad ??= _readPlaylists());
    } catch (_) {
      _playlistLoad = null;
      rethrow;
    }
  }

  Future<void> _readPlaylists() async {
    if (_playlistKey != null) return;
    final generation = _libraryEpoch;
    final identity = await LoomIdentityCoreV1().readIdentity();
    if (identity == null || LoomAppLock.instance.locked) return;
    final key = 'loom.music.playlists.v1.${identity.identityId}';
    final raw = await LoomSecretStorage().read(key: key);
    if (LoomAppLock.instance.locked || generation != _libraryEpoch) return;
    _playlistKey = key;
    try {
      final decoded = raw == null
          ? <String, dynamic>{}
          : jsonDecode(raw) as Map<String, dynamic>;
      playlists = decoded.map(
        (name, ids) => MapEntry(
          name,
          (ids as List).whereType<String>().take(500).toList(),
        ),
      );
    } catch (_) {
      playlists = {};
    }
  }

  Future<void> savePlaylist(String name) async {
    name = name.trim();
    if (name.isEmpty || name.length > 80 || _queue.ids.isEmpty) return;
    await _loadPlaylists();
    if (_playlistKey == null) return;
    playlists[name] = List.of(_queue.ids);
    await LoomSecretStorage().write(
      key: _playlistKey!,
      value: jsonEncode(playlists),
    );
    notifyListeners();
  }

  Future<void> deletePlaylist(String name) async {
    playlists.remove(name);
    if (_playlistKey != null) {
      await LoomSecretStorage().write(
        key: _playlistKey!,
        value: jsonEncode(playlists),
      );
    }
    notifyListeners();
  }

  Future<void> playPlaylist(String name) async {
    final ids =
        playlists[name]?.where((id) => track(id) != null).toList() ?? [];
    if (ids.isEmpty) return;
    _queue.replace(ids);
    await playTrack(ids.first);
  }

  Future<void> playTrack(String id) async {
    final item = track(id);
    if (item != null) {
      _queue.select(id);
      await open(
        item.file,
        id: id,
        title: item.title,
        subtitle: item.artist,
        music: true,
      );
    }
  }

  void removeFromQueue(String id) {
    _queue.remove(id);
    notifyListeners();
  }

  void reorderQueue(int oldIndex, int newIndex) {
    _queue.reorder(oldIndex, newIndex);
    notifyListeners();
  }

  void toggleShuffle() {
    _queue.shuffle = !shuffle;
    notifyListeners();
  }

  void cycleRepeat() {
    _queue.repeat = (repeat + 1) % 3;
    notifyListeners();
  }

  Future<void> next({bool completed = false}) async {
    if (!music) return;
    final nextId = _queue.next(completed: completed);
    if (nextId == sourceId && completed) {
      await seek(Duration.zero);
      await _player?.play();
    } else if (nextId != null) {
      await playTrack(nextId);
    }
  }

  Future<void> previous() async {
    if (position > const Duration(seconds: 3)) {
      await seek(Duration.zero);
      return;
    }
    final id = _queue.previous();
    if (id != null) await playTrack(id);
  }

  Future<void> clearLibrary() async {
    ++_libraryEpoch;
    final items = List.of(_library);
    _library.clear();
    _queue.replace([]);
    playlists = {};
    _playlistKey = null;
    _playlistLoad = null;
    await closeAll();
    for (final item in items) {
      try {
        await item.file.parent.delete(recursive: true);
      } catch (_) {}
    }
  }

  Future<void> _setupSystem() => _systemSetup ??= _initializeSystem();

  Future<void> _initializeSystem() async {
    if (_voiceSession || (!Platform.isAndroid && !Platform.isIOS)) return;
    _session = await AudioSession.instance;
    await _session!.configure(const AudioSessionConfiguration.music());
    // Initialise before audible playback, while the Activity is foreground.
    // Install focus listeners only after init succeeds, avoiding duplicates on
    // a retry (for example a missing notification resource in a release APK).
    _handler = await AudioService.init<_SystemAudioHandler>(
      builder: () => _SystemAudioHandler(this),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'app.loom.messenger.music',
        androidNotificationChannelName: 'Music playback',
        androidNotificationIcon: 'drawable/ic_stat_music',
        // audio_service requires Ongoing=false when foreground is retained on pause.
        androidNotificationOngoing: false,
        androidStopForegroundOnPause: false,
        artDownscaleWidth: 512,
        artDownscaleHeight: 512,
      ),
    );
    _systemPublisher = LoomMusicSystemPublisher(_handler!);
    _sessionSubscriptions.add(
      _session!.interruptionEventStream.listen((event) {
        if (event.begin) unawaited(pauseAll());
      }),
    );
    _sessionSubscriptions.add(
      _session!.becomingNoisyEventStream.listen((_) => unawaited(pauseAll())),
    );
    addListener(_syncSystem);
    // Loading/title may have changed before the service listener existed.
    _syncSystem();
  }

  void _syncSystem() {
    final publisher = _systemPublisher;
    if (publisher == null) return;
    final item = music && visible
        ? MediaItem(
            id: sourceId ?? sourcePath!,
            title: title,
            artist: subtitle,
            duration: duration,
            artUri: artwork?.uri,
            playable: true,
            extras: const {'mediaType': 'music'},
          )
        : null;
    final systemQueue = music && visible
        ? queue
              .map(
                (track) => MediaItem(
                  id: track.id,
                  title: track.title,
                  artist: track.artist,
                  artUri: track.artwork?.uri,
                  playable: true,
                  duration: track.id == sourceId ? duration : null,
                  extras: const {'mediaType': 'music'},
                ),
              )
              .toList()
        : <MediaItem>[];
    final queueIndex = systemQueue.indexWhere((track) => track.id == sourceId);
    publisher.publish(
      item: item,
      queue: systemQueue,
      state: PlaybackState(
        controls: music && visible
            ? [
                MediaControl.skipToPrevious,
                playing ? MediaControl.pause : MediaControl.play,
                MediaControl.skipToNext,
                MediaControl.stop,
              ]
            : [],
        systemActions: music && visible ? const {MediaAction.seek} : const {},
        queueIndex: queueIndex < 0 ? null : queueIndex,
        repeatMode: repeat == 2
            ? AudioServiceRepeatMode.one
            : repeat == 1
            ? AudioServiceRepeatMode.all
            : AudioServiceRepeatMode.none,
        shuffleMode: shuffle
            ? AudioServiceShuffleMode.all
            : AudioServiceShuffleMode.none,
        androidCompactActionIndices: music && visible
            ? const [0, 1, 2]
            : const [],
        processingState: !music || !visible
            ? AudioProcessingState.idle
            : error != null
            ? AudioProcessingState.error
            : loading
            ? AudioProcessingState.loading
            : AudioProcessingState.ready,
        errorCode: error == null ? null : 1,
        errorMessage: error == null ? null : 'Music playback unavailable',
        playing: music && visible && playing,
        updatePosition: position,
        speed: speed,
      ),
    );
  }

  Player? _player;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  File? _file;
  String? sourcePath;
  String? sourceId;
  String title = '', subtitle = '';
  bool playing = false, loading = false;
  String? error;
  Duration duration = Duration.zero;
  double speed = 1;
  List<double> waveform = const [];
  int _epoch = 0;
  Future<void> _operations = Future<void>.value();
  bool get visible => sourcePath != null;
  bool isSource(File file, {String? id}) =>
      id == null ? sourcePath == file.path : sourceId == id;
  void _lockChanged() {
    if (LoomAppLock.instance.locked) {
      unawaited(_voiceSession ? close() : clearLibrary());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && !music) {
      unawaited(pause());
    }
  }

  Future<void> open(
    File source, {
    required String title,
    String? id,
    String subtitle = '',
    List<double> waveform = const [],
    bool music = false,
  }) {
    if (_blocked) return Future<void>.value();
    final request = ++_epoch;
    final focusRequest = ++_focusEpoch;
    return _operations = _operations.catchError((Object _) {}).then((_) async {
      // A superseded request must not pause a newer session in the other player.
      if (request != _epoch || focusRequest != _focusEpoch || _blocked) return;
      await (_voiceSession ? instance : voice).pause();
      await instance._activeVideo?.call();
      instance._activeVideo = null;
      await _release();
      if (request != _epoch || focusRequest != _focusEpoch || _blocked) {
        return;
      }
      sourcePath = source.path;
      sourceId = id;
      this.title = title;
      this.subtitle = subtitle;
      this.waveform = List.unmodifiable(waveform);
      this.music = music;
      artwork = music && id != null ? track(id)?.artwork : null;
      if (music && id != null && !_queue.ids.contains(id)) {
        final group = _musicGroup(id);
        final ids = _library
            .where((item) => _musicGroup(item.id) == group)
            .map((item) => item.id)
            .toList();
        if (!ids.contains(id)) ids.add(id);
        _queue.replace(ids, start: id);
      }
      loading = true;
      error = null;
      position = Duration.zero;
      duration = Duration.zero;
      speed = 1;
      notifyListeners();
      try {
        if (music) {
          try {
            await _setupSystem();
          } catch (_) {
            _systemSetup = null;
            rethrow;
          }
        }
        await LoomMediaAudioRoute.prepare();
        MediaKit.ensureInitialized();
        final temp = await getTemporaryDirectory();
        final root = await Directory(
          '${temp.path}/loom_media_playback',
        ).create(recursive: true);
        final folder = await root.createTemp('session_');
        _file = File(
          '${folder.path}/media${RegExp(r'\.[a-zA-Z0-9]{1,8}$').firstMatch(source.path)?.group(0) ?? '.bin'}',
        );
        await source.copy(_file!.path);
        if (request != _epoch || focusRequest != _focusEpoch || _blocked) {
          await _release();
          return;
        }
        final player = Player();
        _player = player;
        await volume.attach(player.setVolume);
        _subscriptions.addAll([
          player.stream.playing.listen((v) {
            if (playing == v) return;
            playing = v;
            notifyListeners();
          }),
          player.stream.position.listen((v) {
            if ((v - position).abs() < const Duration(milliseconds: 200)) {
              return;
            }
            position = v;
            if ((v - _lastSystemPosition).abs() >= const Duration(seconds: 1)) {
              _lastSystemPosition = v;
              _syncSystem();
            }
          }),
          player.stream.duration.listen((v) {
            if (duration == v) return;
            duration = v;
            notifyListeners();
          }),
          player.stream.completed.listen((completed) {
            if (!completed) return;
            position = duration;
            playing = false;
            notifyListeners();
            if (this.music) unawaited(next(completed: true));
          }),
          player.stream.error.listen((_) {
            error = 'unsupported_media';
            loading = false;
            notifyListeners();
          }),
        ]);
        // The native demuxer probes the contents, rather than trusting extension.
        await player.open(Media(_file!.path), play: false);
        if (request != _epoch || focusRequest != _focusEpoch || _blocked) {
          await _release();
          return;
        }
        await player.play();
        loading = false;
        notifyListeners();
      } catch (_) {
        await _release();
        if (request == _epoch) {
          error = 'unsupported_media';
          loading = false;
          notifyListeners();
        }
      }
    });
  }

  Future<void> toggle() async {
    try {
      if (_blocked) {
        return;
      }
      final focusRequest = ++_focusEpoch;
      if (!playing) {
        await (_voiceSession ? instance : voice).pause();
        await instance._activeVideo?.call();
        instance._activeVideo = null;
      }
      if (!playing && duration > Duration.zero && position >= duration) {
        await _player?.seek(Duration.zero);
      }
      if (!playing) await LoomMediaAudioRoute.prepare();
      if (_blocked || focusRequest != _focusEpoch) {
        return;
      }
      await _player?.playOrPause();
    } catch (_) {
      error = 'playback_failed';
      notifyListeners();
    }
  }

  Future<void> pause() async {
    try {
      await _activeVideo?.call();
      await _player?.pause();
    } catch (_) {}
  }

  Future<void> seek(Duration target) async {
    try {
      if (!LoomAppLock.instance.locked) {
        await _player?.seek(target);
      }
    } catch (_) {}
  }

  Future<void> changeSpeed() async {
    speed = speed == 1
        ? 1.5
        : speed == 1.5
        ? 2
        : 1;
    try {
      await _player?.setRate(speed);
    } catch (_) {
      speed = 1;
    }
    notifyListeners();
  }

  Future<void> close() {
    unawaited(pause());
    ++_epoch;
    sourcePath = null;
    sourceId = null;
    title = '';
    subtitle = '';
    music = false;
    artwork = null;
    if (!_voiceSession && !voice.playing) {
      unawaited(_session?.setActive(false) ?? Future<bool>.value(false));
    }
    waveform = const [];
    position = Duration.zero;
    _lastSystemPosition = Duration.zero;
    loading = false;
    error = null;
    playing = false;
    notifyListeners();
    return _operations = _operations
        .catchError((Object _) {})
        .then((_) => _release());
  }

  Future<void> _release() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    final player = _player;
    volume.detach();
    _player = null;
    try {
      await player?.dispose();
    } catch (_) {}
    final file = _file;
    _file = null;
    if (file != null) {
      try {
        await file.parent.delete(recursive: true);
      } catch (_) {}
    }
    playing = false;
    loading = false;
    notifyListeners();
  }
}

class LoomMusicTrack {
  const LoomMusicTrack(
    this.id,
    this.file,
    this.title,
    this.artist,
    this.artwork,
    this.bytes,
  );
  final String id, title, artist;
  final File file;
  final File? artwork;
  final int bytes;
}

(String?, String?, Uint8List?) _musicTags(String path) {
  try {
    final tags = readMetadata(File(path), getImage: true);
    final covers = tags.pictures.where(
      (p) =>
          p.bytes.length <= 4 * 1024 * 1024 && p.mimetype.startsWith('image/'),
    );
    return (
      tags.title,
      tags.artist,
      covers.isEmpty ? null : covers.first.bytes,
    );
  } catch (_) {
    return (null, null, null);
  }
}

class _SystemAudioHandler extends BaseAudioHandler with SeekHandler {
  _SystemAudioHandler(this.controller);
  final LoomPlaybackController controller;
  @override
  Future<void> play() async {
    if (!controller.playing) await controller.toggle();
  }

  @override
  Future<void> pause() => controller.pause();
  @override
  Future<void> stop() => controller.close();
  @override
  Future<void> seek(Duration position) => controller.seek(position);
  @override
  Future<void> skipToNext() => controller.next();
  @override
  Future<void> skipToPrevious() => controller.previous();
}

String _musicGroup(String id) =>
    id.contains(':') ? id.substring(0, id.lastIndexOf(':')) : id;
