import 'dart:async';

import 'package:loom_calls/loom_calls.dart';
import 'package:loom_design/loom_design.dart';
import 'package:loom_models/loom_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../../app/loom_strings.dart';
import '../application/call_session_controller.dart';
import 'call_error.dart';

class LoomActiveCallRoute extends StatelessWidget {
  const LoomActiveCallRoute({super.key});

  @override
  Widget build(BuildContext context) {
    final calls = LoomCallSessionScope.of(context);
    return AnimatedBuilder(
      animation: calls,
      builder: (context, _) {
        final engine = calls.engine;
        final peer = calls.currentPeer;
        if (engine == null || peer == null) {
          return Scaffold(
            appBar: LoomGlassAppBar(),
            body: Center(
              child: Text(
                tr(
                  context,
                  'There is no active call.',
                  'تماس فعالی وجود ندارد.',
                ),
              ),
            ),
          );
        }
        return LoomActiveCallScreen(
          engine: engine,
          peerLabel: peer.displayName,
          peerAddress: peer.address,
        );
      },
    );
  }
}

class LoomActiveCallScreen extends StatefulWidget {
  const LoomActiveCallScreen({
    required this.engine,
    required this.peerLabel,
    this.peerAddress,
    this.peerImage,
    super.key,
  });

  final LoomCallEngine engine;
  final String peerLabel;
  final String? peerAddress;
  final ImageProvider<Object>? peerImage;

  @override
  State<LoomActiveCallScreen> createState() => _LoomActiveCallScreenState();
}

class _LoomActiveCallScreenState extends State<LoomActiveCallScreen> {
  Timer? _clock;
  bool _chromeVisible = true;
  Offset? _previewPosition;
  bool _draggingPreview = false;

  @override
  void initState() {
    super.initState();
    widget.engine.addListener(_syncClock);
    _syncClock();
  }

  void _syncClock() {
    final ticking =
        widget.engine.state.active && widget.engine.state.answeredAt != null;
    if (ticking) {
      _clock ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) {
          setState(() {});
        }
      });
    } else {
      _clock?.cancel();
      _clock = null;
    }
  }

  @override
  void didUpdateWidget(covariant LoomActiveCallScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.engine != widget.engine) {
      oldWidget.engine.removeListener(_syncClock);
      widget.engine.addListener(_syncClock);
      _syncClock();
    }
  }

  @override
  void dispose() {
    widget.engine.removeListener(_syncClock);
    _clock?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Theme(
    data: LoomTheme.dark(
      fontFamily: Theme.of(context).textTheme.bodyMedium?.fontFamily,
    ).copyWith(platform: Theme.of(context).platform),
    child: Builder(
      builder: (context) => AnimatedBuilder(
        animation: widget.engine,
        builder: (context, _) {
          final state = widget.engine.state;
          final remote = widget.engine.remoteRenderer;
          final local = widget.engine.localRenderer;
          final video = state.kind == LoomCallKind.video;
          final terminal =
              state.lifecycle == LoomCallLifecycle.ended ||
              state.lifecycle == LoomCallLifecycle.failed;
          final visible = terminal || !video || _chromeVisible;
          final reduced = LoomAccessibility.fromContext(context).reduceMotion;
          final duration = reduced ? Duration.zero : LoomMotion.component;
          final showRemote =
              video &&
              remote != null &&
              state.remoteVideoAvailable &&
              state.remoteCameraEnabled;
          return Scaffold(
            backgroundColor: Colors.black,
            body: SafeArea(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final wrapped = video && constraints.maxWidth < 390;
                  final textScale =
                      MediaQuery.textScalerOf(context).scale(11) / 11;
                  final controlsHeight = terminal
                      ? 90.0
                      : (wrapped ? 2 : 1) * (66 + 26 * textScale) + 24;
                  final previewWidth = constraints.maxWidth < 360
                      ? 88.0
                      : 108.0;
                  final previewHeight = constraints.maxHeight < 450
                      ? 84.0
                      : 144.0;
                  const minY = 80.0;
                  final maxY =
                      (constraints.maxHeight -
                              controlsHeight -
                              previewHeight -
                              20)
                          .clamp(minY, double.infinity)
                          .toDouble();
                  final maxX = (constraints.maxWidth - previewWidth - 12)
                      .clamp(12.0, double.infinity)
                      .toDouble();
                  final position = _previewPosition ?? Offset(maxX, minY);
                  final x = position.dx.clamp(12.0, maxX).toDouble();
                  final y = position.dy.clamp(minY, maxY).toDouble();
                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: video && !terminal
                        ? () => setState(() => _chromeVisible = !_chromeVisible)
                        : null,
                    child: Stack(
                      children: [
                        Positioned.fill(
                          // Crossfade instead of a hard cut when the remote
                          // camera stream appears or drops mid-call.
                          child: AnimatedSwitcher(
                            duration: duration,
                            child: showRemote
                                ? RepaintBoundary(
                                    key: const ValueKey('remote-video'),
                                    child: RTCVideoView(
                                      remote,
                                      objectFit: RTCVideoViewObjectFit
                                          .RTCVideoViewObjectFitCover,
                                    ),
                                  )
                                : _CallBackdrop(
                                    key: const ValueKey('call-backdrop'),
                                    peerLabel: widget.peerLabel,
                                    peerImage: widget.peerImage,
                                    state: state,
                                    bottomInset: controlsHeight + 20,
                                    compact: constraints.maxHeight < 620,
                                  ),
                          ),
                        ),
                        if (showRemote)
                          const Positioned(
                            top: 0,
                            left: 0,
                            right: 0,
                            height: 150,
                            child: IgnorePointer(
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [
                                      Colors.black87,
                                      Colors.transparent,
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        if (video &&
                            state.cameraEnabled &&
                            local != null &&
                            !terminal &&
                            constraints.maxHeight >
                                controlsHeight + previewHeight + 100)
                          AnimatedPositioned(
                            left: x,
                            top: y,
                            width: previewWidth,
                            height: previewHeight,
                            duration: _draggingPreview
                                ? Duration.zero
                                : duration,
                            curve: LoomMotion.emphasized,
                            child: Semantics(
                              label: tr(
                                context,
                                'Your camera preview',
                                'پیش‌نمایش دوربین شما',
                              ),
                              child: GestureDetector(
                                onTap: () {},
                                onPanStart: (_) =>
                                    setState(() => _draggingPreview = true),
                                onPanUpdate: (details) => setState(() {
                                  _previewPosition = Offset(
                                    (x + details.delta.dx)
                                        .clamp(12.0, maxX)
                                        .toDouble(),
                                    (y + details.delta.dy)
                                        .clamp(minY, maxY)
                                        .toDouble(),
                                  );
                                }),
                                onPanEnd: (_) => setState(() {
                                  _draggingPreview = false;
                                  _previewPosition = Offset(
                                    x < maxX / 2 ? 12 : maxX,
                                    y,
                                  );
                                }),
                                onPanCancel: () =>
                                    setState(() => _draggingPreview = false),
                                child: Container(
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(20),
                                    border: Border.all(color: Colors.white.withAlphaFraction(.24)),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.black.withAlphaFraction(.24),
                                        blurRadius: 18,
                                      ),
                                    ],
                                  ),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(19),
                                    child: RepaintBoundary(
                                      child: RTCVideoView(
                                        local,
                                        mirror: true,
                                        objectFit: RTCVideoViewObjectFit
                                            .RTCVideoViewObjectFitCover,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        PositionedDirectional(
                          start: 8,
                          end: 8,
                          top: 8,
                          child: ExcludeSemantics(
                            excluding: !visible,
                            child: IgnorePointer(
                              ignoring: !visible,
                              child: AnimatedOpacity(
                                opacity: visible ? 1 : 0,
                                duration: duration,
                                child: _TopChrome(
                                  peerLabel: widget.peerLabel,
                                  state: state,
                                  onBack: () =>
                                      Navigator.of(context).maybePop(),
                                ),
                              ),
                            ),
                          ),
                        ),
                        PositionedDirectional(
                          start: 12,
                          end: 12,
                          bottom: 14,
                          child: ExcludeSemantics(
                            excluding: !visible,
                            child: IgnorePointer(
                              ignoring: !visible,
                              child: AnimatedSlide(
                                offset: visible
                                    ? Offset.zero
                                    : const Offset(0, 1.3),
                                duration: duration,
                                curve: LoomMotion.emphasized,
                                child: AnimatedOpacity(
                                  opacity: visible ? 1 : 0,
                                  duration: duration,
                                  child: AnimatedSwitcher(
                                    duration: duration,
                                    switchInCurve: LoomMotion.emphasized,
                                    child: terminal
                                        ? _EndedControls(
                                            key: const ValueKey('ended'),
                                            state: state,
                                            onClose: () =>
                                                Navigator.of(context).maybePop(),
                                          )
                                        : _LiveControls(
                                            key: const ValueKey('live'),
                                            engine: widget.engine,
                                            state: state,
                                            wrapped: wrapped,
                                          ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          );
        },
      ),
    ),
  );
}

class _TopChrome extends StatelessWidget {
  const _TopChrome({
    required this.peerLabel,
    required this.state,
    required this.onBack,
  });
  final String peerLabel;
  final LoomCallSnapshot state;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      LoomPressable(
        child: IconButton.filledTonal(
          onPressed: onBack,
          tooltip: tr(context, 'Back to chats', 'بازگشت به گفتگوها'),
          icon: const LoomDirectionalIcon(LoomIcons.arrow_back_rounded),
        ),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              peerLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: LoomTheme.darkPalette.textPrimary,
                fontWeight: FontWeight.w700,
              ),
            ),
            Text(
              state.answeredAt != null && state.active
                  ? _duration(state.duration)
                  : _statusText(context, state),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: LoomTheme.darkPalette.textSecondary, fontSize: 12),
            ),
          ],
        ),
      ),
      if (state.quality != LoomCallQuality.unknown)
        _QualityBadge(quality: state.quality),
    ],
  );
}

class _CallBackdrop extends StatelessWidget {
  const _CallBackdrop({
    required this.peerLabel,
    required this.peerImage,
    required this.state,
    required this.bottomInset,
    required this.compact,
    super.key,
  });
  final String peerLabel;
  final ImageProvider<Object>? peerImage;
  final LoomCallSnapshot state;
  final double bottomInset;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final connecting = {
      LoomCallLifecycle.preparing,
      LoomCallLifecycle.ringing,
      LoomCallLifecycle.connecting,
      LoomCallLifecycle.reconnecting,
    }.contains(state.lifecycle);
    // The call stage stays intentionally dark in every appearance; colors come
    // from the shared midnight palette instead of local literals.
    final stage = LoomTheme.darkPalette;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: const Alignment(0, -.5),
          radius: 1.3,
          colors: [
            Color.alphaBlend(
              context.loom.primary.withAlphaFraction(.14),
              stage.surfaceElevated,
            ),
            stage.surfaceElevated,
            stage.background,
          ],
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(24, 76, 24, bottomInset),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: (constraints.maxHeight - 76 - bottomInset)
                  .clamp(0.0, double.infinity)
                  .toDouble(),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                LoomConnectionPulse(
                  active: connecting,
                  size: compact ? 108 : 156,
                  child: LoomAvatar(
                    label: peerLabel,
                    image: peerImage,
                    size: compact ? 78 : 116,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  peerLabel,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    color: stage.textPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                AnimatedSwitcher(
                  duration: LoomAccessibility.fromContext(context).reduceMotion
                      ? Duration.zero
                      : LoomMotion.component,
                  child: Text(
                    _statusText(context, state),
                    key: ValueKey(_statusText(context, state)),
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70),
                  ),
                ),
                if (state.kind == LoomCallKind.video &&
                    state.lifecycle == LoomCallLifecycle.connected &&
                    !state.remoteCameraEnabled) ...[
                  const SizedBox(height: 8),
                  Text(
                    tr(
                      context,
                      'Their camera is off',
                      'دوربین طرف مقابل خاموش است',
                    ),
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70),
                  ),
                ],
                const SizedBox(height: 16),
                Wrap(
                  alignment: WrapAlignment.center,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 5,
                  children: [
                    const Icon(
                      LoomIcons.lock_outline_rounded,
                      size: 14,
                      color: Colors.white60,
                    ),
                    Text(
                      tr(context, 'Encrypted call', 'تماس رمزگذاری‌شده'),
                      style: const TextStyle(
                        color: Colors.white60,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _QualityBadge extends StatelessWidget {
  const _QualityBadge({required this.quality});
  final LoomCallQuality quality;

  @override
  Widget build(BuildContext context) {
    final (label, bars) = switch (quality) {
      LoomCallQuality.excellent => (tr(context, 'Excellent', 'عالی'), 4),
      LoomCallQuality.good => (tr(context, 'Good', 'خوب'), 3),
      LoomCallQuality.constrained => (tr(context, 'Limited', 'محدود'), 2),
      LoomCallQuality.poor => (tr(context, 'Poor', 'ضعیف'), 1),
      LoomCallQuality.unknown => ('', 0),
    };
    final description = tr(
      context,
      'Connection quality: $label',
      'کیفیت اتصال: $label',
    );
    return Tooltip(
      message: description,
      child: Semantics(
        label: description,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: List.generate(
              4,
              (index) => Container(
                margin: const EdgeInsetsDirectional.only(start: 2),
                width: 3,
                height: 5 + index * 3,
                decoration: BoxDecoration(
                  color: index < bars ? Colors.white : Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LiveControls extends StatelessWidget {
  const _LiveControls({
    required this.engine,
    required this.state,
    required this.wrapped,
    super.key,
  });
  final LoomCallEngine engine;
  final LoomCallSnapshot state;
  final bool wrapped;

  @override
  Widget build(BuildContext context) {
    final video = state.kind == LoomCallKind.video;
    final controls = [
      _Action(
        key: const ValueKey('mute'),
        icon: state.muted ? LoomIcons.mic_off_rounded : LoomIcons.mic_rounded,
        label: state.muted
            ? tr(context, 'Unmute', 'وصل صدا')
            : tr(context, 'Mute', 'بی‌صدا'),
        selected: state.muted,
        onTap: () => engine.setMuted(!state.muted),
      ),
      if (video)
        _Action(
          key: const ValueKey('camera'),
          icon: state.cameraEnabled
              ? LoomIcons.videocam_rounded
              : LoomIcons.videocam_off_rounded,
          label: state.cameraEnabled
              ? tr(context, 'Camera off', 'قطع تصویر')
              : tr(context, 'Camera on', 'وصل تصویر'),
          selected: !state.cameraEnabled,
          onTap: () => engine.setCameraEnabled(!state.cameraEnabled),
        ),
      if (video)
        _Action(
          key: const ValueKey('switch'),
          icon: LoomIcons.cameraswitch_rounded,
          label: tr(context, 'Flip', 'چرخش'),
          onTap: state.cameraEnabled ? engine.switchCamera : null,
        ),
      _Action(
        key: const ValueKey('speaker'),
        icon: state.speakerEnabled
            ? LoomIcons.volume_up_rounded
            : LoomIcons.hearing_rounded,
        label: state.speakerEnabled
            ? tr(context, 'Earpiece', 'گوشی')
            : tr(context, 'Speaker', 'بلندگو'),
        selected: state.speakerEnabled,
        onTap: () => engine.setSpeakerEnabled(!state.speakerEnabled),
      ),
      _Action(
        key: const ValueKey('end'),
        icon: LoomIcons.call_end_rounded,
        label: tr(context, 'End call', 'پایان تماس'),
        destructive: true,
        onTap: engine.hangUp,
      ),
    ];
    return LoomGlassSurface(
      strength: LoomGlassStrength.strong,
      radius: LoomRadii.sheet,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final count = wrapped ? 3 : controls.length;
          final width = (constraints.maxWidth - 8 * (count - 1)) / count;
          return Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 12,
            children: [
              for (final control in controls)
                SizedBox(width: width, child: control),
            ],
          );
        },
      ),
    );
  }
}

class _EndedControls extends StatelessWidget {
  const _EndedControls({required this.state, required this.onClose, super.key});
  final LoomCallSnapshot state;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => LoomGlassSurface(
    strength: LoomGlassStrength.strong,
    radius: LoomRadii.sheet,
    padding: const EdgeInsets.all(14),
    child: Row(
      children: [
        Expanded(
          child: Text(
            _statusText(context, state),
            style: const TextStyle(color: Colors.white),
          ),
        ),
        const SizedBox(width: 12),
        LoomPressable(
          child: FilledButton(
            onPressed: onClose,
            child: Text(tr(context, 'Close', 'بستن')),
          ),
        ),
      ],
    ),
  );
}

class _Action extends StatefulWidget {
  const _Action({
    required this.icon,
    required this.label,
    this.onTap,
    this.destructive = false,
    this.selected = false,
    super.key,
  });
  final IconData icon;
  final String label;
  final Future<void> Function()? onTap;
  final bool destructive;
  final bool selected;

  @override
  State<_Action> createState() => _ActionState();
}

class _ActionState extends State<_Action> {
  bool _busy = false;

  Future<void> _invoke() async {
    if (_busy || widget.onTap == null) {
      return;
    }
    setState(() => _busy = true);
    try {
      await widget.onTap!();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              tr(
                context,
                'Could not change the call. Please try again.',
                'تغییر تماس انجام نشد. دوباره تلاش کنید.',
              ),
            ),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final enabled = !_busy && widget.onTap != null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          toggled: widget.destructive ? null : widget.selected,
          child: LoomPressable(
            enabled: enabled,
            child: IconButton.filled(
              onPressed: enabled ? _invoke : null,
              tooltip: widget.label,
              icon: _busy
                  ? const LoomBusyIndicator(color: Colors.white)
                  : Icon(widget.icon),
              style: IconButton.styleFrom(
                minimumSize: const Size.square(48),
                backgroundColor: widget.destructive
                    ? LoomTheme.darkPalette.critical
                    : widget.selected
                    ? LoomTheme.darkPalette.textPrimary
                    : Colors.white.withAlphaFraction(.12),
                foregroundColor: widget.selected && !widget.destructive
                    ? LoomTheme.darkPalette.background
                    : Colors.white,
                disabledForegroundColor: Colors.white38,
                disabledBackgroundColor: Colors.white.withAlphaFraction(.06),
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        ExcludeSemantics(
          child: Text(
            widget.label,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white70, fontSize: 11),
          ),
        ),
      ],
    );
  }
}

String _statusText(BuildContext context, LoomCallSnapshot state) {
  if (state.lifecycle == LoomCallLifecycle.failed) {
    if (state.error != null) return callFailureMessage(context, state.error!);
    return switch (state.endReason) {
      LoomCallEndReason.permissionDenied => tr(
        context,
        'Microphone or camera permission denied',
        'مجوز میکروفون یا دوربین رد شد',
      ),
      LoomCallEndReason.signalingFailure => tr(
        context,
        'Could not reach the other person',
        'ارتباط با طرف مقابل برقرار نشد',
      ),
      _ => tr(context, 'Connection failed', 'اتصال ناموفق بود'),
    };
  }
  if (state.lifecycle == LoomCallLifecycle.ended) {
    return switch (state.endReason) {
      LoomCallEndReason.timeout => tr(context, 'No answer', 'پاسخی نبود'),
      LoomCallEndReason.busy => tr(context, 'Busy', 'مشغول'),
      LoomCallEndReason.rejected => tr(context, 'Declined', 'رد شد'),
      _ => tr(context, 'Call ended', 'تماس پایان یافت'),
    };
  }
  return switch (state.lifecycle) {
    LoomCallLifecycle.idle => tr(context, 'Ready', 'آماده'),
    LoomCallLifecycle.preparing => tr(
      context,
      'Preparing…',
      'در حال آماده‌سازی…',
    ),
    LoomCallLifecycle.ringing when !state.remoteRinging => tr(
      context,
      'Calling…',
      'در حال تماس…',
    ),
    LoomCallLifecycle.ringing => tr(context, 'Ringing…', 'در حال زنگ خوردن…'),
    LoomCallLifecycle.connecting => tr(context, 'Connecting…', 'در حال اتصال…'),
    LoomCallLifecycle.connected => tr(context, 'Connected', 'متصل'),
    LoomCallLifecycle.reconnecting => tr(
      context,
      'Reconnecting…',
      'اتصال مجدد…',
    ),
    LoomCallLifecycle.ended => tr(context, 'Call ended', 'تماس پایان یافت'),
    LoomCallLifecycle.failed => tr(
      context,
      'Connection failed',
      'اتصال ناموفق بود',
    ),
  };
}

String _duration(Duration value) {
  final seconds = value.inSeconds.clamp(0, 99 * 60 * 60).toInt();
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  if (h > 0) {
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
  return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
}
