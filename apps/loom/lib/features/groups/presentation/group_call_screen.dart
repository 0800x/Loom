import 'dart:async';

import 'package:loom_crypto_bridge/loom_crypto_bridge.dart';
import 'package:loom_design/loom_design.dart';
import 'package:flutter/material.dart';

import '../../../app/loom_strings.dart';
import '../application/group_call_controller.dart';
import '../application/group_call_models.dart';

const loomGroupCallRoute = '/group-call';
Future<void> showLoomGroupCall(BuildContext context, String id) =>
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        settings: const RouteSettings(name: loomGroupCallRoute),
        builder: (_) => LoomGroupCallScreen(groupId: id),
      ),
    );

class LoomGroupCallRouteObserver extends NavigatorObserver {
  final visible = ValueNotifier<bool>(false);
  void _update(Route<dynamic>? r) {
    if (r is PopupRoute) {
      return;
    }
    visible.value = r?.settings.name == loomGroupCallRoute;
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _update(route);
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _update(previousRoute);
  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      _update(newRoute);
}

class LoomGroupCallOverlayHost extends StatelessWidget {
  const LoomGroupCallOverlayHost({
    required this.navigatorKey,
    required this.observer,
    required this.child,
    super.key,
  });
  final GlobalKey<NavigatorState> navigatorKey;
  final LoomGroupCallRouteObserver observer;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final calls = LoomGroupCallScope.of(context), id = calls.activeGroupId;
    return ValueListenableBuilder<bool>(
      valueListenable: observer.visible,
      builder: (context, visible, _) => Column(
        children: [
          if (calls.isActive &&
              id != null &&
              !visible &&
              !LoomAppLock.instance.locked)
            SafeArea(
              bottom: false,
              child: LoomGlassSurface(
                radius: 0,
                padding: EdgeInsets.zero,
                child: ListTile(
                  minVerticalPadding: LoomSpacing.sm,
                  leading: const Icon(LoomIcons.groups_outlined),
                  title: Text(
                    calls.group?.title ??
                        tr(context, 'Group call', 'تماس گروه'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    tr(
                      context,
                      'Tap to return to the call',
                      'برای برگشت به تماس بزنید',
                    ),
                  ),
                  onTap: () => navigatorKey.currentState?.push<void>(
                    MaterialPageRoute(
                      settings: const RouteSettings(name: loomGroupCallRoute),
                      builder: (_) => LoomGroupCallScreen(groupId: id),
                    ),
                  ),
                  trailing: IconButton(
                    tooltip: tr(context, 'Leave call', 'خروج از تماس'),
                    icon: const Icon(LoomIcons.call_end_rounded),
                    onPressed: () => unawaited(calls.leave()),
                  ),
                ),
              ),
            ),
          Expanded(child: child),
        ],
      ),
    );
  }
}

String groupCallError(BuildContext c, String code) => switch (code) {
  'not_configured' || 'server_update_required' => tr(
    c,
    'Update your home server and enable group calls.',
    'سرور خانه را به‌روز و تماس گروه را فعال کنید.',
  ),
  'removed' => tr(
    c,
    'You were removed from this call.',
    'از این تماس خارج شدید.',
  ),
  'join_locked' => tr(
    c,
    'The admin has locked entry.',
    'مدیر ورود به تماس را بسته است.',
  ),
  'full' => tr(c, 'This call is full.', 'ظرفیت تماس پر است.'),
  'other_device' => tr(
    c,
    'Your account is in this call on another device.',
    'حساب شما با دستگاه دیگری در این تماس است.',
  ),
  'permission_required' => tr(
    c,
    'You no longer have permission for this action.',
    'دیگر اجازهٔ انجام این کار را ندارید.',
  ),
  'media_permission' => tr(
    c,
    'Check microphone or camera permission.',
    'دسترسی میکروفن یا دوربین را بررسی کنید.',
  ),
  'keys_changed' => tr(
    c,
    'The group changed. Start a new call with current members.',
    'گروه تغییر کرد. با اعضای فعلی تماس تازه‌ای شروع کنید.',
  ),
  'authorization_lost' => tr(
    c,
    'The server connection was lost. Rejoin when it returns.',
    'ارتباط با سرور قطع شد. پس از اتصال دوباره وارد شوید.',
  ),
  'ended' => tr(c, 'The call has ended.', 'تماس پایان یافت.'),
  'changed' => tr(
    c,
    'The call changed. Refresh and try again.',
    'تماس تغییر کرد. تازه‌سازی کنید و دوباره امتحان کنید.',
  ),
  'rate_limited' => tr(
    c,
    'Please wait before trying again.',
    'کمی صبر کنید و دوباره امتحان کنید.',
  ),
  _ => tr(
    c,
    'Could not connect to the group call. Try again.',
    'اتصال به تماس گروه ممکن نشد. دوباره امتحان کنید.',
  ),
};

class LoomGroupCallScreen extends StatefulWidget {
  const LoomGroupCallScreen({required this.groupId, super.key});
  final String groupId;
  @override
  State<LoomGroupCallScreen> createState() => _LoomGroupCallScreenState();
}

class _LoomGroupCallScreenState extends State<LoomGroupCallScreen> {
  LoomGroupCallController? _calls;
  LoomGroupCallLobby? _lobby;
  bool _loading = false, _wasActive = false, _entering = false;
  String? _error;
  String _mode = 'open';
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final calls = LoomGroupCallScope.of(context);
    if (_wasActive && !calls.isActive && _calls == calls) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          unawaited(_refresh());
        }
      });
    }
    _wasActive = calls.isActive && calls.activeGroupId == widget.groupId;
    if (_calls != calls) {
      _calls = calls;
      unawaited(_refresh());
    }
  }

  Future<void> _refresh() async {
    if (_loading) {
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await _calls!.inspect(widget.groupId);
      if (mounted) {
        setState(() => _lobby = result);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'unavailable');
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _enter({String? kind}) async {
    if (_entering || _loading || _calls!.busy || _calls!.isActive) return;
    setState(() => _entering = true);
    try {
      await _calls!.join(widget.groupId, startKind: kind, mode: _mode);
      if (mounted && !_calls!.isActive) await _refresh();
    } finally {
      if (mounted) setState(() => _entering = false);
    }
  }

  Future<void> _control(
    String action, {
    LoomGroupCallParticipant? target,
    String? mode,
    bool? locked,
  }) async {
    if (['end', 'remove'].contains(action)) {
      final yes = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(
            action == 'end'
                ? tr(c, 'End call for everyone?', 'تماس برای همه پایان یابد؟')
                : tr(c, 'Remove from this call?', 'از این تماس خارج شود؟'),
          ),
          content: Text(
            action == 'end'
                ? tr(
                    c,
                    'Everyone will be disconnected.',
                    'اتصال همه قطع می‌شود.',
                  )
                : tr(
                    c,
                    'They cannot rejoin this call.',
                    'این فرد نمی‌تواند دوباره وارد همین تماس شود.',
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: Text(tr(c, 'Cancel', 'لغو')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              style: FilledButton.styleFrom(
                backgroundColor: c.loom.critical,
                foregroundColor: Theme.of(c).colorScheme.onError,
              ),
              child: Text(
                action == 'end'
                    ? tr(c, 'End for everyone', 'پایان برای همه')
                    : tr(c, 'Remove', 'حذف'),
              ),
            ),
          ],
        ),
      );
      if (yes != true || !mounted) {
        return;
      }
    }
    await _calls!.control(
      action,
      participantId: target?.id,
      mode: mode,
      locked: locked,
    );
  }

  @override
  Widget build(BuildContext context) {
    final calls = LoomGroupCallScope.of(context),
        group = calls.groups.groups
            .where((g) => g.id == widget.groupId)
            .firstOrNull;
    final role = group?.members
        .where((m) => m.deviceId == calls.groups.ownDeviceId)
        .firstOrNull
        ?.role;
    final admin = role == 'owner' || role == 'admin',
        active = calls.isActive && calls.activeGroupId == widget.groupId;
    final call = active ? calls.call : _lobby?.call;
    return Scaffold(
      appBar: LoomGlassAppBar(
        leading: active
            ? IconButton(
                tooltip: tr(context, 'Minimize call', 'کوچک کردن تماس'),
                icon: const Icon(LoomIcons.keyboard_arrow_down_rounded),
                onPressed: () => Navigator.maybePop(context),
              )
            : null,
        title: Text(
          group?.title ?? tr(context, 'Group call', 'تماس گروه'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          if (!active)
            IconButton(
              tooltip: tr(context, 'Refresh', 'تازه‌سازی'),
              onPressed: _loading ? null : _refresh,
              icon: const Icon(LoomIcons.refresh),
            ),
          if (active && admin)
            PopupMenuButton<String>(
              icon: const Icon(LoomIcons.more_vert_rounded),
              tooltip: tr(context, 'Manage call', 'مدیریت تماس'),
              onSelected: calls.busy
                  ? null
                  : (action) {
                      if (action == 'mode') {
                        unawaited(
                          _control(
                            'set_mode',
                            mode: call?.mode == 'open' ? 'approval' : 'open',
                          ),
                        );
                      } else if (action == 'lock') {
                        unawaited(
                          _control(
                            'set_join_locked',
                            locked: call?.joinLocked != true,
                          ),
                        );
                      } else {
                        unawaited(_control('end'));
                      }
                    },
              itemBuilder: (c) => [
                PopupMenuItem(
                  value: 'mode',
                  child: Text(
                    call?.mode == 'open'
                        ? tr(
                            c,
                            'Require permission to speak',
                            'صحبت با اجازهٔ مدیر',
                          )
                        : tr(
                            c,
                            'Allow everyone to speak',
                            'همه بتوانند صحبت کنند',
                          ),
                  ),
                ),
                PopupMenuItem(
                  value: 'lock',
                  child: Text(
                    call?.joinLocked == true
                        ? tr(c, 'Unlock entry', 'باز کردن ورود')
                        : tr(c, 'Lock entry', 'قفل کردن ورود'),
                  ),
                ),
                PopupMenuItem(
                  value: 'end',
                  child: Text(
                    tr(c, 'End call for everyone', 'پایان تماس برای همه'),
                    style: TextStyle(color: c.loom.critical),
                  ),
                ),
              ],
            ),
        ],
      ),
      body: SafeArea(
        child: active && call != null
            ? LoomGroupCallSurface(
                call: call,
                ownId: calls.ownParticipantId,
                admin: admin,
                owner: role == 'owner',
                joining:
                    calls.phase == LoomGroupCallPhase.joining ||
                    calls.media?.connected != true,
                busy: calls.busy,
                microphone: calls.media?.microphoneEnabled ?? false,
                camera: calls.media?.cameraEnabled ?? false,
                speaker: calls.speakerEnabled,
                speakers: calls.media?.speakers ?? {},
                video: (id) => calls.media?.video(id),
                error: calls.error,
                onMicrophone: () => unawaited(calls.toggleMicrophone()),
                onCamera: () => unawaited(calls.toggleCamera()),
                onSwitchCamera: () => unawaited(calls.switchCamera()),
                onSpeaker: calls.media?.supportsSpeakerphone == true
                    ? () => unawaited(calls.toggleSpeaker())
                    : null,
                onLeave: () => unawaited(calls.leave()),
                onControl: (a, p) => unawaited(_control(a, target: p)),
              )
            : Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: LoomSizing.formMax,
                  ),
                  child: ListView(
                    padding: const EdgeInsets.all(24),
                    children: [
                      const SizedBox(height: 32),
                      const Icon(LoomIcons.groups_outlined, size: 64),
                      const SizedBox(height: 20),
                      Text(
                        tr(
                          context,
                          'Group voice & video',
                          'تماس صوتی و تصویری گروه',
                        ),
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        tr(
                          context,
                          'Join with your microphone and camera off. Turn them on when you are ready.',
                          'با میکروفن و دوربین خاموش وارد می‌شوید. هر وقت آماده بودید آن‌ها را روشن کنید.',
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 24),
                      if (_loading || _entering)
                        const Center(child: CircularProgressIndicator())
                      else if (_error != null || calls.error != null)
                        LoomFeedbackSurface(
                          message: groupCallError(
                            context,
                            calls.error ?? _error!,
                          ),
                          actionLabel: tr(context, 'Retry', 'تلاش مجدد'),
                          onAction: _loading || _entering ? null : _refresh,
                        ),
                      if (!_loading && _lobby?.available == false)
                        Text(
                          tr(
                            context,
                            'Group calls need to be enabled on your home server.',
                            'تماس گروه باید روی سرور خانه فعال شود.',
                          ),
                          textAlign: TextAlign.center,
                        ),
                      if (!_loading &&
                          _lobby?.available == true &&
                          call?.phase == 'active') ...[
                        Text(
                          '${call!.participants.length} ${tr(context, 'in this call', 'نفر در تماس')}',
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 16),
                        FilledButton.icon(
                          onPressed: calls.isActive || calls.busy || _entering
                              ? null
                              : () => unawaited(_enter()),
                          icon: const Icon(LoomIcons.call_outlined),
                          label: Text(tr(context, 'Join call', 'ورود به تماس')),
                        ),
                      ] else if (!_loading &&
                          _lobby?.available == true &&
                          admin) ...[
                        DropdownButtonFormField<String>(
                          initialValue: _mode,
                          decoration: InputDecoration(
                            labelText: tr(
                              context,
                              'Who can speak?',
                              'چه کسی می‌تواند صحبت کند؟',
                            ),
                          ),
                          items: [
                            DropdownMenuItem(
                              value: 'open',
                              child: Text(tr(context, 'Everyone', 'همه')),
                            ),
                            DropdownMenuItem(
                              value: 'approval',
                              child: Text(
                                tr(
                                  context,
                                  'With admin approval',
                                  'با اجازهٔ مدیر',
                                ),
                              ),
                            ),
                          ],
                          onChanged: _entering || calls.busy
                              ? null
                              : (v) => setState(() => _mode = v ?? 'open'),
                        ),
                        const SizedBox(height: 20),
                        FilledButton.icon(
                          onPressed: calls.isActive || calls.busy || _entering
                              ? null
                              : () => unawaited(_enter(kind: 'audio')),
                          icon: const Icon(LoomIcons.call_outlined),
                          label: Text(
                            tr(context, 'Start voice call', 'شروع تماس صوتی'),
                          ),
                        ),
                        if (_lobby!.video) ...[
                          const SizedBox(height: 12),
                          OutlinedButton.icon(
                            onPressed: calls.isActive || calls.busy || _entering
                                ? null
                                : () => unawaited(_enter(kind: 'video')),
                            icon: const Icon(LoomIcons.videocam_outlined),
                            label: Text(
                              tr(
                                context,
                                'Start video call',
                                'شروع تماس تصویری',
                              ),
                            ),
                          ),
                        ],
                      ] else if (!_loading && _lobby?.available == true)
                        Text(
                          tr(
                            context,
                            'There is no active call. An admin can start one.',
                            'تماسی در جریان نیست. مدیر گروه می‌تواند تماس را شروع کند.',
                          ),
                          textAlign: TextAlign.center,
                        ),
                      if (calls.isActive && !active)
                        Text(
                          tr(
                            context,
                            'Leave your current call first.',
                            'اول از تماس فعلی خارج شوید.',
                          ),
                          textAlign: TextAlign.center,
                        ),
                    ],
                  ),
                ),
              ),
      ),
    );
  }
}

class LoomGroupCallSurface extends StatelessWidget {
  const LoomGroupCallSurface({
    required this.call,
    required this.ownId,
    required this.admin,
    required this.owner,
    required this.joining,
    required this.busy,
    required this.microphone,
    required this.camera,
    required this.speaker,
    required this.speakers,
    required this.video,
    required this.onMicrophone,
    required this.onCamera,
    required this.onSwitchCamera,
    required this.onSpeaker,
    required this.onLeave,
    required this.onControl,
    this.error,
    super.key,
  });
  final LoomGroupCallSnapshot call;
  final String? ownId, error;
  final bool admin, owner, joining, busy, microphone, camera, speaker;
  final Set<String> speakers;
  final Widget? Function(String) video;
  final VoidCallback onMicrophone, onCamera, onSwitchCamera, onLeave;
  final VoidCallback? onSpeaker;
  final void Function(String, LoomGroupCallParticipant?) onControl;
  @override
  Widget build(BuildContext context) {
    final own = call.participants.where((p) => p.id == ownId).firstOrNull,
        ready = !joining && !busy;
    final ordered = [...call.participants]
      ..sort(
        (a, b) => (a.handRaisedAt ?? 9223372036854775807).compareTo(
          b.handRaisedAt ?? 9223372036854775807,
        ),
      );
    return Column(
      children: [
        Expanded(
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: LoomSizing.contentMax,
              ),
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        Text(
                          joining
                              ? tr(context, 'Connecting…', 'در حال اتصال…')
                              : '${call.participants.length} ${tr(context, 'participants', 'شرکت‌کننده')}',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          call.mode == 'approval'
                              ? tr(
                                  context,
                                  'Raise your hand to ask to speak',
                                  'برای درخواست صحبت دستتان را بالا ببرید',
                                )
                              : tr(
                                  context,
                                  'Everyone can speak',
                                  'همه می‌توانند صحبت کنند',
                                ),
                          textAlign: TextAlign.center,
                        ),
                        if (call.joinLocked)
                          Text(tr(context, 'Entry locked', 'ورود بسته است')),
                        if (error != null)
                          Text(
                            groupCallError(context, error!),
                            textAlign: TextAlign.center,
                          ),
                      ],
                    ),
                  ),

                  if (call.kind == 'video')
                    LayoutBuilder(
                      builder: (context, box) => Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final p in call.participants)
                            SizedBox(
                              width: box.maxWidth > 600
                                  ? (box.maxWidth - 8) / 2
                                  : box.maxWidth,
                              height: 220,
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(20),
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    video(p.id) ??
                                        Center(
                                          child: LoomAvatar(
                                            label: p.name,
                                            size: LoomSizing.largeAvatar,
                                          ),
                                        ),
                                    PositionedDirectional(
                                      start: 12,
                                      end: 12,
                                      bottom: 12,
                                      child: Text(
                                        p.name,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          backgroundColor: Colors.black54,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  for (final p in ordered)
                    ListTile(
                      contentPadding: const EdgeInsets.symmetric(vertical: 4),
                      leading: DecoratedBox(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: speakers.contains(p.id)
                                ? context.loom.connectivity
                                : Colors.transparent,
                            width: LoomBorders.selectedRail,
                          ),
                        ),
                        child: LoomAvatar(
                          label: p.name,
                          size: LoomSizing.compactAvatar,
                        ),
                      ),
                      title: Text(
                        '${p.name}${p.id == ownId ? ' · ${tr(context, 'You', 'شما')}' : ''}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        p.handRaisedAt != null
                            ? tr(context, 'Wants to speak', 'درخواست صحبت')
                            : speakers.contains(p.id)
                            ? tr(context, 'Speaking', 'در حال صحبت')
                            : p.state == 'joining'
                            ? tr(context, 'Connecting', 'در حال اتصال')
                            : p.microphone
                            ? tr(context, 'Can speak', 'اجازهٔ صحبت دارد')
                            : tr(context, 'Listening', 'شنونده'),
                      ),
                      trailing:
                          admin &&
                              p.id != ownId &&
                              (owner || p.role == 'member')
                          ? PopupMenuButton<String>(
                              icon: const Icon(LoomIcons.more_vert_rounded),
                              tooltip: tr(
                                context,
                                'Participant controls',
                                'کنترل شرکت‌کننده',
                              ),
                              onSelected: (a) => onControl(a, p),
                              itemBuilder: (c) => [
                                PopupMenuItem(
                                  value: 'allow_speak',
                                  child: Text(
                                    tr(c, 'Allow to speak', 'اجازهٔ صحبت'),
                                  ),
                                ),
                                if (p.handRaisedAt != null)
                                  PopupMenuItem(
                                    value: 'deny_request',
                                    child: Text(
                                      tr(c, 'Decline request', 'رد درخواست'),
                                    ),
                                  ),
                                PopupMenuItem(
                                  value: 'mute',
                                  child: Text(
                                    tr(c, 'Mute microphone', 'بستن میکروفن'),
                                  ),
                                ),
                                PopupMenuItem(
                                  value: 'revoke_speak',
                                  child: Text(
                                    tr(
                                      c,
                                      'Remove speaking permission',
                                      'گرفتن اجازهٔ صحبت',
                                    ),
                                  ),
                                ),
                                if (call.kind == 'video')
                                  PopupMenuItem(
                                    value: p.camera
                                        ? 'disable_camera'
                                        : 'allow_camera',
                                    child: Text(
                                      p.camera
                                          ? tr(
                                              c,
                                              'Disable camera',
                                              'بستن دوربین',
                                            )
                                          : tr(
                                              c,
                                              'Allow camera',
                                              'اجازهٔ دوربین',
                                            ),
                                    ),
                                  ),
                                PopupMenuItem(
                                  value: 'remove',
                                  child: Text(
                                    tr(c, 'Remove from call', 'اخراج از تماس'),
                                  ),
                                ),
                              ],
                            )
                          : p.role != 'member'
                          ? Text(
                              p.role == 'owner'
                                  ? tr(context, 'Owner', 'مالک')
                                  : tr(context, 'Admin', 'مدیر'),
                            )
                          : null,
                    ),
                ],
              ),
            ),
          ),
        ),
        if (own != null)
          Visibility(
            visible: !own.microphone || own.handRaisedAt != null,
            maintainSize: true,
            maintainState: true,
            maintainAnimation: true,
            child: TextButton.icon(
              key: const ValueKey('group-call-request-speak'),
              onPressed: ready
                  ? () => onControl(
                      own.handRaisedAt == null ? 'raise_hand' : 'lower_hand',
                      null,
                    )
                  : null,
              icon: const Icon(LoomIcons.arrow_upward),
              label: Text(
                own.handRaisedAt == null
                    ? tr(context, 'Request to speak', 'درخواست صحبت')
                    : tr(context, 'Cancel request', 'لغو درخواست'),
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.all(LoomSpacing.sm),
          child: Center(
            heightFactor: 1,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: LoomSizing.formMax),
              child: LoomGlassSurface(
                radius: LoomRadii.navigation,
                padding: const EdgeInsets.all(LoomSpacing.sm),
                child: LayoutBuilder(
                  builder: (context, box) {
                    final controls = <Widget>[
                      LoomCallControl(
                        key: const ValueKey('group-call-speaker'),
                        label: tr(context, 'Speaker', 'بلندگو'),
                        tooltip: onSpeaker == null
                            ? tr(
                                context,
                                'Choose audio output in your device settings',
                                'خروجی صدا را در تنظیمات دستگاه انتخاب کنید',
                              )
                            : speaker
                            ? tr(
                                context,
                                'Turn speaker off',
                                'خاموش کردن بلندگو',
                              )
                            : tr(
                                context,
                                'Turn speaker on',
                                'روشن کردن بلندگو',
                              ),
                        active: onSpeaker != null && speaker,
                        onPressed: ready ? onSpeaker : null,
                        icon: speaker
                            ? LoomIcons.volume_up_rounded
                            : LoomIcons.volume_off_outlined,
                      ),
                      LoomCallControl(
                        key: const ValueKey('group-call-microphone'),
                        label: microphone
                            ? tr(context, 'Mic on', 'میکروفن روشن')
                            : tr(context, 'Mic off', 'میکروفن خاموش'),
                        tooltip: microphone
                            ? tr(context, 'Mute', 'قطع صدا')
                            : own?.microphone == true
                            ? tr(context, 'Unmute', 'باز کردن صدا')
                            : tr(
                                context,
                                'Speaking permission required',
                                'صحبت به اجازه نیاز دارد',
                              ),
                        active: microphone,
                        onPressed:
                            ready && (own?.microphone == true || microphone)
                            ? onMicrophone
                            : null,
                        icon: microphone
                            ? LoomIcons.mic
                            : LoomIcons.mic_off_rounded,
                      ),
                      if (call.kind == 'video') ...[
                        LoomCallControl(
                          key: const ValueKey('group-call-camera'),
                          label: camera
                              ? tr(context, 'Camera on', 'دوربین روشن')
                              : tr(context, 'Camera off', 'دوربین خاموش'),
                          tooltip: camera
                              ? tr(
                                  context,
                                  'Turn camera off',
                                  'خاموش کردن دوربین',
                                )
                              : own?.camera == true
                              ? tr(
                                  context,
                                  'Turn camera on',
                                  'روشن کردن دوربین',
                                )
                              : tr(
                                  context,
                                  'Camera permission required',
                                  'دوربین به اجازه نیاز دارد',
                                ),
                          active: camera,
                          onPressed: ready && (own?.camera == true || camera)
                              ? onCamera
                              : null,
                          icon: camera
                              ? LoomIcons.videocam_outlined
                              : LoomIcons.videocam_off_rounded,
                        ),
                        LoomCallControl(
                          key: const ValueKey('group-call-switch-camera'),
                          label: tr(context, 'Switch', 'تعویض'),
                          tooltip: tr(context, 'Switch camera', 'تعویض دوربین'),
                          onPressed: ready && camera ? onSwitchCamera : null,
                          icon: LoomIcons.cameraswitch_rounded,
                        ),
                      ],
                      LoomCallControl(
                        key: const ValueKey('group-call-leave'),
                        label: tr(context, 'Leave', 'خروج'),
                        tooltip: tr(context, 'Leave call', 'خروج از تماس'),
                        destructive: true,
                        onPressed: onLeave,
                        icon: LoomIcons.call_end_rounded,
                      ),
                    ];
                    final columns = box.maxWidth < 440 && controls.length > 3
                        ? 3
                        : controls.length;
                    final width =
                        (box.maxWidth - LoomSpacing.xs * (columns - 1)) /
                        columns;
                    return Wrap(
                      spacing: LoomSpacing.xs,
                      runSpacing: LoomSpacing.sm,
                      alignment: WrapAlignment.center,
                      children: [
                        for (final control in controls)
                          SizedBox(width: width, child: control),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
