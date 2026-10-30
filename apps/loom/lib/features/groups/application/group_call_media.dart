import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'group_call_models.dart';
import 'group_call_subscription.dart';
import 'package:flutter/services.dart';

abstract class LoomGroupCallMedia extends ChangeNotifier {
  bool get connected;
  bool get supportsSpeakerphone => true;
  bool get microphoneEnabled;
  bool get cameraEnabled;
  Set<String> get speakers;
  Future<void> connect(Uri uri, String token, Uint8List key);
  Future<void> applyPolicy(LoomGroupCallSnapshot call, String ownId);
  Future<void> microphone(bool enabled);
  Future<void> camera(bool enabled);
  Future<void> speakerphone(bool enabled);
  Future<void> switchCamera();
  Widget? video(String participantId);
  Future<void> close();
}

class LoomLiveKitGroupCallMedia extends LoomGroupCallMedia {
  lk.Room? _room;
  lk.BaseKeyProvider? _keys;
  lk.EventsListener<lk.RoomEvent>? _events;
  LoomGroupCallSnapshot? _policy;
  String? _own;
  bool _closed = false, _syncing = false, _encryptionReady = false;
  int _generation = 0;
  bool _subscriptionDirty = false;
  final _requested = <String>{};
  bool _audioRouteAvailable = true;
  @override
  bool get supportsSpeakerphone =>
      _audioRouteAvailable &&
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);
  @override
  bool get connected =>
      !_closed && _room?.connectionState == lk.ConnectionState.connected;
  @override
  bool get microphoneEnabled =>
      _room?.localParticipant?.isMicrophoneEnabled() ?? false;
  @override
  bool get cameraEnabled => _room?.localParticipant?.isCameraEnabled() ?? false;
  @override
  Set<String> get speakers =>
      _room?.activeSpeakers.map((p) => p.identity).toSet() ?? {};
  @override
  Future<void> connect(Uri uri, String token, Uint8List key) async {
    if (_closed || _room != null || key.length != 32 || kIsWeb) {
      throw StateError('Encrypted media unavailable');
    }
    lk.disableLogging();
    final generation = _generation;
    final keys = await lk.BaseKeyProvider.create(
      sharedKey: true,
      keyRingSize: 1,
      ratchetWindowSize: 0,
      failureTolerance: 0,
      uncryptedMagicBytes: '',
      discardFrameWhenCryptorNotReady: true,
    );
    _keys = keys;
    try {
      await keys.setRawKey(key);
      if (_closed || generation != _generation) {
        throw StateError('Call closed');
      }
      final room = lk.Room(
        roomOptions: lk.RoomOptions(
          adaptiveStream: true,
          dynacast: true,
          encryption: lk.E2EEOptions(keyProvider: keys),
          defaultVideoPublishOptions: const lk.VideoPublishOptions(
            videoCodec: 'vp8',
            simulcast: true,
          ),
          defaultCameraCaptureOptions: const lk.CameraCaptureOptions(
            params: lk.VideoParameters(
              dimensions: lk.VideoDimensions(640, 360),
              encoding: lk.VideoEncoding(maxBitrate: 500000, maxFramerate: 24),
            ),
          ),
        ),
      );
      _room = room;
      room.addListener(_changed);
      _events = room.createListener();
      _events!.on<lk.TrackUnsubscribedEvent>(
        (e) => _requested.remove(e.publication.sid),
      );
      _events!.on<lk.TrackSubscriptionExceptionEvent>((event) {
        if (event.sid != null) {
          _requested.remove(event.sid);
        } else {
          _requested.clear();
        }
      });
      _events!.on<lk.ParticipantPermissionsUpdatedEvent>(
        (_) => unawaited(_subscriptions()),
      );
      _events!.on<lk.TrackSubscriptionPermissionChangedEvent>(
        (_) => unawaited(_subscriptions()),
      );
      _events!.on<lk.RoomReconnectedEvent>((_) {
        _requested.clear();
        unawaited(_subscriptions());
      });
      // SDK skips native frame cryptors for unencrypted/AV1 tracks. Never
      // auto-subscribe: require both current admission and supported encryption.
      await room.connect(
        uri.toString(),
        token,
        connectOptions: const lk.ConnectOptions(autoSubscribe: false),
      );
      if (_closed || generation != _generation || room.e2eeManager == null) {
        throw StateError('Encrypted media unavailable');
      }
      await room.setE2EEEnabled(true);
      _encryptionReady = true;
      await _subscriptions();
      // Output routing is optional; unsupported desktop speakerphone methods
      // must never tear down an otherwise encrypted, authorized connection.
      try {
        await speakerphone(true);
      } on MissingPluginException {
        _audioRouteAvailable = false;
      } on PlatformException {
        _audioRouteAvailable = false;
      }
      notifyListeners();
    } catch (_) {
      await close();
      await _destroyKeys();
      rethrow;
    }
  }

  void _changed() {
    if (_closed) {
      return;
    }
    unawaited(_subscriptions());
    notifyListeners();
  }

  @override
  Future<void> applyPolicy(LoomGroupCallSnapshot call, String ownId) async {
    _policy = call;
    _own = ownId;
    final own = call.participants.where((p) => p.id == ownId).firstOrNull;
    if (own == null || call.phase != 'active') {
      await close();
      return;
    }
    if (!own.microphone && microphoneEnabled) {
      await microphone(false);
    }
    if (!own.camera && cameraEnabled) {
      await camera(false);
    }
    await _subscriptions();
  }

  bool _encrypted(lk.RemoteTrackPublication p) =>
      p.encryptionType == lk.EncryptionType.kGcm &&
      ((p.source == lk.TrackSource.microphone &&
              p.mimeType.toLowerCase() == 'audio/opus') ||
          (p.source == lk.TrackSource.camera &&
              ['video/vp8', 'video/h264'].contains(p.mimeType.toLowerCase())));
  Future<void> _subscriptions() async {
    final room = _room, policy = _policy;
    if (_syncing) {
      _subscriptionDirty = true;
      return;
    }
    if (_closed ||
        room == null ||
        policy == null ||
        !_encryptionReady ||
        !connected) {
      return;
    }
    _syncing = true;
    try {
      final own = policy.participants.where((p) => p.id == _own).firstOrNull;
      for (final peer in room.remoteParticipants.values) {
        final admitted = policy.participants.any(
          (p) => p.id == peer.identity && p.state == 'connected',
        );
        for (final publication in peer.trackPublications.values) {
          if (_closed || _policy != policy) {
            return;
          }
          try {
            await syncLoomGroupTrack(
              publication,
              _requested,
              authorized:
                  own?.subscribe == true &&
                  room.localParticipant?.permissions.canSubscribe == true &&
                  admitted &&
                  _encrypted(publication),
            );
          } catch (_) {
            /* A later grant/policy refresh retries the request. */
          }
        }
      }
    } finally {
      _syncing = false;
      if (_subscriptionDirty) {
        _subscriptionDirty = false;
        unawaited(_subscriptions());
      }
    }
  }

  @override
  Future<void> microphone(bool enabled) async {
    if (_closed) {
      return;
    }
    final own = _policy?.participants.where((p) => p.id == _own).firstOrNull;
    if (enabled && (own?.microphone != true || !connected)) {
      throw StateError('Speaking permission required');
    }
    await _room?.localParticipant?.setMicrophoneEnabled(enabled);
    if (!_closed) {
      notifyListeners();
    }
  }

  @override
  Future<void> camera(bool enabled) async {
    if (_closed) {
      return;
    }
    final own = _policy?.participants.where((p) => p.id == _own).firstOrNull;
    if (enabled && (own?.camera != true || !connected)) {
      throw StateError('Camera permission required');
    }
    await _room?.localParticipant?.setCameraEnabled(enabled);
    if (!_closed) {
      notifyListeners();
    }
  }

  @override
  Future<void> speakerphone(bool enabled) => supportsSpeakerphone
      ? rtc.Helper.setSpeakerphoneOn(enabled)
      : Future<void>.value();
  @override
  Future<void> switchCamera() async {
    final track = _room?.localParticipant?.videoTrackPublications
        .where((p) => p.source == lk.TrackSource.camera)
        .firstOrNull
        ?.track;
    if (track is lk.LocalVideoTrack) {
      await track.setCameraPosition(
        track.currentOptions is lk.CameraCaptureOptions &&
                (track.currentOptions as lk.CameraCaptureOptions)
                        .cameraPosition ==
                    lk.CameraPosition.front
            ? lk.CameraPosition.back
            : lk.CameraPosition.front,
      );
    }
  }

  @override
  Widget? video(String id) {
    final room = _room;
    if (_closed || room == null) {
      return null;
    }
    final ownIdentity = room.localParticipant?.identity;
    final isLocal = id == ownIdentity;
    if (isLocal) {
      final track = room.localParticipant?.videoTrackPublications
          .where(
            (p) =>
                p.source == lk.TrackSource.camera &&
                !p.muted &&
                p.encryptionType == lk.EncryptionType.kGcm,
          )
          .firstOrNull
          ?.track;
      // Local preview mirrors like a physical mirror; remote tiles must not.
      return track != null
          ? lk.VideoTrackRenderer(
              track,
              mirrorMode: lk.VideoViewMirrorMode.mirror,
            )
          : null;
    }
    final track = room.remoteParticipants[id]?.videoTrackPublications
        .where(
          (p) =>
              p.source == lk.TrackSource.camera &&
              !p.muted &&
              p.encryptionType == lk.EncryptionType.kGcm,
        )
        .firstOrNull
        ?.track;
    return track != null
        ? lk.VideoTrackRenderer(
            track,
            mirrorMode: lk.VideoViewMirrorMode.off,
          )
        : null;
  }

  Future<void> _destroyKeys() async {
    final keys = _keys;
    _keys = null;
    keys?.sharedKey?.fillRange(0, keys.sharedKey!.length, 0);
    await keys?.keyProvider.dispose();
  }

  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    _encryptionReady = false;
    ++_generation;
    final room = _room;
    _room = null;
    room?.removeListener(_changed);
    try {
      await _events?.dispose();
      _events = null;
      await room?.disconnect();
    } finally {
      try {
        await room?.dispose();
      } finally {
        await _destroyKeys();
      }
    }
    _policy = null;
    _own = null;
    _requested.clear();
  }
}
