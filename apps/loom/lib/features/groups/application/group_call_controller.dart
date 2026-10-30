import 'dart:async';
import 'dart:typed_data';
import 'package:loom_crypto_bridge/loom_crypto_bridge.dart';
import 'package:loom_models/loom_models.dart';
import 'package:loom_protocol/loom_protocol.dart';
import 'package:flutter/widgets.dart';
import '../../calls/application/call_platform_bridge.dart';
import '../../media/application/playback_controller.dart';
import 'groups_controller.dart';
import 'group_call_models.dart';
import 'group_call_media.dart';

class LoomGroupCallLobby {
  const LoomGroupCallLobby(this.available, this.video, this.maximum, this.call);
  final bool available, video;
  final int maximum;
  final LoomGroupCallSnapshot? call;
}

enum LoomGroupCallPhase { idle, joining, connected, ending }

class LoomGroupCallController extends ChangeNotifier {
  LoomGroupCallController({
    required this.groups,
    required this.otherCallActive,
    LoomGroupCallMedia Function()? mediaFactory,
    LoomCallPlatformBridge? platform,
    this.heartbeatInterval = const Duration(seconds: 2),
    this.authorizationTimeout = const Duration(seconds: 8),
  }) : _factory = mediaFactory ?? LoomLiveKitGroupCallMedia.new,
       _platform = platform ?? LoomCallPlatformBridge() {
    groups.addListener(_groupsChanged);
    LoomAppLock.instance.addListener(_locked);
  }
  final LoomGroupsController groups;
  final bool Function() otherCallActive;
  final LoomGroupCallMedia Function() _factory;
  final LoomCallPlatformBridge _platform;
  final Duration heartbeatInterval, authorizationTimeout;
  LoomGroupCallPhase phase = LoomGroupCallPhase.idle;
  LoomGroupCallSnapshot? call;
  LoomGroupCallMedia? media;
  String? activeGroupId, ownParticipantId, error;
  bool busy = false, speakerEnabled = true, _disposed = false, _polling = false;
  int _generation = 0;
  Timer? _heartbeat, _watchdog;
  DateTime? _lastAuthorized, _admissionDeadline;

  /// Client-side join instant; powers the in-call duration readout.
  DateTime? connectedAt;
  Duration get connectedDuration => connectedAt == null
      ? Duration.zero
      : DateTime.now().difference(connectedAt!);
  Uint8List? _connectingKey;
  Future<void>? _leaving;
  Future<void> _mediaTail = Future.value();
  String? _nativeActivity;
  bool get isActive => phase != LoomGroupCallPhase.idle;
  LoomGroupState? get group =>
      groups.groups.where((g) => g.id == activeGroupId).firstOrNull;
  LoomGroupCallParticipant? get own =>
      call?.participants.where((p) => p.id == ownParticipantId).firstOrNull;
  void _guard(int generation) {
    if (_disposed || LoomAppLock.instance.locked || generation != _generation) {
      throw StateError('Call closed');
    }
  }

  Future<LoomGroupCallSnapshot?> _decode(String id, Object? raw) async {
    if (raw == null) {
      return null;
    }
    final json = Map<String, Object?>.from(raw as Map);
    var group = groups.groups.where((g) => g.id == id).firstOrNull;
    if (group == null ||
        (json['phase'] == 'active' && group.epoch != json['epoch'])) {
      await groups.synchronize();
      group = groups.groups.where((g) => g.id == id).firstOrNull;
    }
    if (group == null ||
        (json['phase'] == 'active' && group.epoch != json['epoch'])) {
      throw StateError('Group keys changed');
    }
    return LoomGroupCallSnapshot.fromJson(json, group);
  }

  Future<LoomGroupCallLobby> inspect(String id) async {
    final r = await groups.callRequest(id, '');
    return LoomGroupCallLobby(
      r['available'] == true,
      r['video'] != false,
      r['maximum'] as int? ?? 16,
      await _decode(id, r['call']),
    );
  }

  Uri _uri(Object? raw) {
    final uri = raw is String ? Uri.tryParse(raw) : null,
        endpoint = groups.onboarding.nodes.selectedEndpoint;
    final local =
        endpoint?.scheme == 'http' &&
        ['localhost', '127.0.0.1', '::1'].contains(endpoint?.host);
    final home = groups.onboarding.receipt?.homeNode.toLowerCase();
    if (uri == null ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.path != '/conference' ||
        (uri.scheme != 'wss' && !(local && uri.scheme == 'ws')) ||
        (uri.authority.toLowerCase() != home &&
            !(local && uri.authority == endpoint?.authority))) {
      throw StateError('Unsafe media endpoint');
    }
    return uri;
  }

  Future<bool> join(
    String id, {
    String? startKind,
    String mode = 'open',
  }) async {
    if (_disposed ||
        isActive ||
        otherCallActive() ||
        LoomAppLock.instance.locked) {
      return false;
    }
    final generation = ++_generation;
    Uint8List? key;
    activeGroupId = id;
    phase = LoomGroupCallPhase.joining;
    busy = true;
    error = null;
    speakerEnabled = true;
    notifyListeners();
    try {
      await LoomPlaybackController.pauseAll();
      _guard(generation);
      final r = startKind == null
          ? await groups.callRequest(id, '')
          : await groups.callRequest(id, 'start', {
              'kind': startKind,
              'mode': mode,
            });
      _guard(generation);
      final selected = await _decode(id, r['call']);
      _guard(generation);
      if (selected == null || selected.phase != 'active') {
        throw StateError('No active call');
      }
      call = selected;
      key = await groups.exportCallKey(id, selected.id, selected.epoch);
      _guard(generation);
      _connectingKey = key;
      final joined = await groups.callRequest(id, 'join', {
        'callId': selected.id,
      });
      _guard(generation);
      call = await _decode(id, joined['call']);
      _guard(generation);
      if (call?.id != selected.id || call?.epoch != selected.epoch) {
        throw StateError('Call changed');
      }
      ownParticipantId = joined['participantId'] as String;
      if (own?.accountId != groups.ownAccountId ||
          own?.deviceId != groups.ownDeviceId) {
        throw StateError('Membership mismatch');
      }
      final token = joined['token'];
      if (token is! String || token.isEmpty || token.length > 8192) {
        throw StateError('Invalid call token');
      }
      final uri = _uri(joined['url']), next = _factory();
      media = next;
      next.addListener(_mediaChanged);
      _lastAuthorized = DateTime.now();
      _admissionDeadline = DateTime.now().add(const Duration(seconds: 30));
      _heartbeat = Timer.periodic(heartbeatInterval, (_) => unawaited(_poll()));
      _watchdog = Timer.periodic(const Duration(milliseconds: 500), (_) {
        final last = _lastAuthorized;
        if (isActive &&
            last != null &&
            DateTime.now().difference(last) > authorizationTimeout) {
          unawaited(leave(reason: 'authorization_lost'));
        }
      });
      await next.connect(uri, token, key);
      _guard(generation);
      key.fillRange(0, key.length, 0);
      _connectingKey = null;
      phase = LoomGroupCallPhase.connected;
      connectedAt = DateTime.now();
      busy = false;
      await _poll();
      _guard(generation);
      await _native();
      notifyListeners();
      return true;
    } catch (failure) {
      if (!_disposed && generation == _generation) {
        error = _safe(failure);
        await leave();
      }
      return false;
    } finally {
      key?.fillRange(0, key.length, 0);
      if (identical(_connectingKey, key)) {
        _connectingKey = null;
      }
    }
  }

  String _safe(Object failure) {
    if (failure is LoomGroupProtocolException) {
      return switch (failure.code) {
        'not_found' => 'server_update_required',
        'group_calls_not_configured' => 'not_configured',
        'group_call_removed' => 'removed',
        'group_call_join_locked' => 'join_locked',
        'group_call_full' => 'full',
        'group_call_other_device' => 'other_device',
        'group_call_changed' || 'group_call_exists' => 'changed',
        'group_call_admin_required' ||
        'group_call_owner_required' => 'permission_required',
        'rate_limited' || 'group_call_request_rate_limited' => 'rate_limited',
        _ => 'unavailable',
      };
    }
    return 'unavailable';
  }

  Future<void> _poll() async {
    if (_polling ||
        !isActive ||
        call == null ||
        activeGroupId == null ||
        phase == LoomGroupCallPhase.ending) {
      return;
    }
    _polling = true;
    final generation = _generation;
    try {
      final r = await groups.callRequest(activeGroupId!, 'heartbeat', {
        'callId': call!.id,
      });
      _guard(generation);
      final next = await _decode(activeGroupId!, r['call']);
      _guard(generation);
      if (next == null ||
          next.phase != 'active' ||
          next.id != call!.id ||
          next.epoch != call!.epoch) {
        await leave(reason: 'ended');
        return;
      }
      call = next;
      _lastAuthorized = DateTime.now();
      if (own == null) {
        await leave(reason: 'removed');
        return;
      }
      if (own!.state == 'connected') {
        _admissionDeadline = null;
      }
      if (_admissionDeadline != null &&
          DateTime.now().isAfter(_admissionDeadline!)) {
        await leave(reason: 'unavailable');
        return;
      }
      await media?.applyPolicy(next, ownParticipantId!);
      _guard(generation);
      await _native();
      notifyListeners();
    } catch (failure) {
      if (!_disposed &&
          generation == _generation &&
          failure is LoomGroupProtocolException &&
          [401, 403, 409, 423].contains(failure.status)) {
        await leave(reason: _safe(failure));
      }
    } finally {
      if (generation == _generation) {
        _polling = false;
      }
    }
  }

  void _mediaChanged() {
    if (!_disposed && isActive) {
      notifyListeners();
    }
  }

  Future<bool> control(
    String action, {
    String? participantId,
    String? mode,
    bool? locked,
  }) async {
    if (busy || call == null || activeGroupId == null || !isActive) {
      return false;
    }
    final generation = _generation;
    busy = true;
    error = null;
    notifyListeners();
    try {
      final r = await groups.callRequest(activeGroupId!, 'control', {
        'callId': call!.id,
        'action': action,
        'expectedRevision': call!.revision,
        if (participantId != null) 'participantId': participantId,
        if (mode != null) 'mode': mode,
        if (locked != null) 'locked': locked,
      });
      _guard(generation);
      final next = await _decode(activeGroupId!, r['call']);
      _guard(generation);
      if (next == null || next.phase == 'ended') {
        await leave(reason: 'ended');
        return true;
      }
      call = next;
      await media?.applyPolicy(next, ownParticipantId!);
      _guard(generation);
      await _native();
      return true;
    } catch (failure) {
      if (!_disposed && generation == _generation) {
        error = _safe(failure);
      }
      return false;
    } finally {
      if (!_disposed && generation == _generation) {
        busy = false;
        notifyListeners();
      }
    }
  }

  Future<void> _capture(Future<void> Function(LoomGroupCallMedia) action) {
    final generation = _generation,
        result = _mediaTail.then((_) async {
          if (_disposed ||
              generation != _generation ||
              LoomAppLock.instance.locked) {
            return;
          }
          final current = media;
          if (current == null || phase != LoomGroupCallPhase.connected) {
            return;
          }
          try {
            await action(current);
            _guard(generation);
            await _native();
          } catch (_) {
            if (!_disposed && generation == _generation) {
              error = 'media_permission';
              notifyListeners();
            }
          }
        });
    _mediaTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<void> toggleMicrophone() =>
      _capture((m) => m.microphone(!m.microphoneEnabled));
  Future<void> toggleCamera() => _capture((m) => m.camera(!m.cameraEnabled));
  Future<void> switchCamera() => _capture((m) => m.switchCamera());
  Future<void> toggleSpeaker() => _capture((m) async {
    if (!m.supportsSpeakerphone) return;
    final enabled = !speakerEnabled;
    await m.speakerphone(enabled);
    speakerEnabled = enabled;
    if (!_disposed) {
      notifyListeners();
    }
  });
  Future<void> _native() async {
    if (phase != LoomGroupCallPhase.connected ||
        media == null ||
        call == null) {
      return;
    }
    final signature =
        '${call!.id}:${media!.microphoneEnabled}:${media!.cameraEnabled}';
    if (_nativeActivity == signature) {
      return;
    }
    _nativeActivity = signature;
    await _platform.startOngoing(
      callId: call!.id,
      peerName: group?.title ?? 'Group call',
      video: call!.kind == 'video',
      microphoneActive: media!.microphoneEnabled,
      cameraActive: media!.cameraEnabled,
    );
  }

  Future<void> leave({String? reason}) {
    if (_leaving != null) {
      return _leaving!;
    }
    if (!isActive) {
      return Future.value();
    }
    final id = activeGroupId, callId = call?.id, current = media;
    ++_generation;
    _polling = false;
    _mediaTail = Future.value();
    phase = LoomGroupCallPhase.ending;
    connectedAt = null;
    _heartbeat?.cancel();
    _heartbeat = null;
    _watchdog?.cancel();
    _watchdog = null;
    _connectingKey?.fillRange(0, _connectingKey!.length, 0);
    _connectingKey = null;
    current?.removeListener(_mediaChanged);
    media = null;
    if (reason != null) {
      error = reason;
    }
    if (!_disposed) {
      notifyListeners();
    }
    final future = () async {
      try {
        await current?.close();
      } catch (_) {
        /* continue teardown */
      }
      current?.dispose();
      try {
        await _platform.stopOngoing();
      } catch (_) {
        /* clear local state anyway */
      }
      _nativeActivity = null;
      if (id != null && callId != null) {
        unawaited(
          groups
              .callRequest(id, 'leave', {'callId': callId})
              .catchError((Object _) => <String, Object?>{}),
        );
      }
      call = null;
      activeGroupId = null;
      ownParticipantId = null;
      busy = false;
      phase = LoomGroupCallPhase.idle;
      if (!_disposed) {
        notifyListeners();
      }
    }();
    _leaving = future.whenComplete(() => _leaving = null);
    return _leaving!;
  }

  void _groupsChanged() {
    if (!isActive || call == null) {
      return;
    }
    final current = group;
    if (current == null ||
        current.epoch != call!.epoch ||
        !current.members.any((m) => m.deviceId == groups.ownDeviceId)) {
      unawaited(leave(reason: 'keys_changed'));
    }
  }

  void _locked() {
    if (LoomAppLock.instance.locked) {
      unawaited(leave(reason: 'locked'));
    }
  }

  @override
  void dispose() {
    _disposed = true;
    groups.removeListener(_groupsChanged);
    LoomAppLock.instance.removeListener(_locked);
    unawaited(leave());
    super.dispose();
  }
}

class LoomGroupCallScope extends InheritedNotifier<LoomGroupCallController> {
  const LoomGroupCallScope({
    required LoomGroupCallController controller,
    required super.child,
    super.key,
  }) : super(notifier: controller);
  static LoomGroupCallController of(BuildContext context) => maybeOf(context)!;
  static LoomGroupCallController? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<LoomGroupCallScope>()
      ?.notifier;
}
