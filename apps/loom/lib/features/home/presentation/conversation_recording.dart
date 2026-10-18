part of 'messenger_shell.dart';

class _NativeVoiceBackend implements VoiceRecorderBackend {
  AudioRecorder? _recorder;
  Directory? _folder;
  AudioRecorder get recorder => _recorder ??= AudioRecorder();
  @override
  Future<bool> permission() => recorder.hasPermission();
  @override
  Future<void> start() async {
    await LoomPlaybackController.pauseAll();
    final temp = await getTemporaryDirectory();
    final root = await Directory(
      '${temp.path}/loom_media_record',
    ).create(recursive: true);
    _folder = await root.createTemp('voice_');
    final file = File('${_folder!.path}/voice.m4a');
    await recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.aacLc,
        bitRate: 64000,
        sampleRate: 44100,
        numChannels: 1,
      ),
      path: file.path,
    );
  }

  @override
  Stream<double> get amplitudes => recorder
      .onAmplitudeChanged(const Duration(milliseconds: 120))
      .map((a) => ((a.current + 60) / 60).clamp(0.0, 1.0).toDouble());
  @override
  Future<File?> stop() async {
    final path = await recorder.stop();
    return path == null ? null : File(path);
  }

  @override
  Future<void> cancel() async {
    try {
      await _recorder?.cancel();
    } catch (_) {}
    try {
      await _folder?.delete(recursive: true);
    } catch (_) {}
    _folder = null;
  }

  @override
  Future<void> dispose() async {
    await _recorder?.dispose();
  }
}

class _VideoNoteBackend implements VoiceRecorderBackend {
  CameraController? camera;
  Directory? _folder;
  final cameraSelection = LoomVideoNoteCameraSelection();
  @override
  Future<bool> permission() async {
    final devices = await availableCameras();
    final selected = cameraSelection.updateDevices(devices);
    if (selected == null) return false;
    camera = CameraController(
      selected,
      ResolutionPreset.medium,
      enableAudio: true,
    );
    await camera!.initialize();
    await camera!.lockCaptureOrientation(DeviceOrientation.portraitUp);
    return true;
  }

  @override
  Future<void> start() async {
    await LoomPlaybackController.pauseAll();
    final temp = await getTemporaryDirectory();
    final root = await Directory(
      '${temp.path}/loom_media_record',
    ).create(recursive: true);
    _folder = await root.createTemp('video_');
    await camera!.startVideoRecording();
  }

  @override
  Stream<double> get amplitudes => const Stream.empty();
  @override
  Future<File?> stop() async {
    final capture = await camera!.stopVideoRecording();
    final source = File(capture.path);
    try {
      final output = '${_folder!.path}/video.mp4';
      if (Platform.isAndroid) {
        await normalizeLoomVideoNote(source.path, output);
        return File(output);
      }
      return await source.copy(output);
    } finally {
      try {
        await source.delete();
      } catch (_) {}
      final current = camera;
      camera = null;
      try {
        await current?.dispose();
      } catch (_) {}
    }
  }

  @override
  Future<void> cancel() async {
    final current = camera;
    camera = null;
    try {
      if (current?.value.isRecordingVideo == true) {
        final capture = await current!.stopVideoRecording();
        try {
          await File(capture.path).delete();
        } catch (_) {}
      }
    } finally {
      try {
        await current?.dispose();
      } catch (_) {}
      try {
        await _folder?.delete(recursive: true);
      } catch (_) {}
      _folder = null;
    }
  }

  @override
  Future<void> dispose() => cancel();
}

/// Stays mounted during input/recording/review/sending rebuilds. In particular
/// the action's GestureDetector is never replaced during a held gesture.
class _InlineVoiceComposer extends StatefulWidget {
  const _InlineVoiceComposer({
    required this.controller,
    required this.focusNode,
    required this.enabled,
    required this.sending,
    required this.onSend,
    required this.onAttach,
    required this.onVoiceSend,
    required this.onVideoSend,
    this.onContentInserted,
    this.onAttachmentOrigin,
    super.key,
  });
  final ValueChanged<KeyboardInsertedContent>? onContentInserted;
  final ValueChanged<Rect?>? onAttachmentOrigin;
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool enabled, sending;
  final VoidCallback? onSend, onAttach;
  final Future<bool> Function(File, Duration) onVideoSend;
  final Future<bool> Function(File, List<double>, Duration) onVoiceSend;
  @override
  State<_InlineVoiceComposer> createState() => _InlineVoiceComposerState();
}

class _InlineVoiceComposerState extends State<_InlineVoiceComposer>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _previewMotion;
  final _recordActionKey = GlobalKey();
  final _attachmentKey = GlobalKey();
  String? _lastVisualState;
  late final VoiceDraftController _audio, _videoDraft;
  late final _VideoNoteBackend _camera;
  VoiceDraftController get _voice => _video ? _videoDraft : _audio;
  final _overlay = OverlayPortalController();
  int _gestureEpoch = 0;
  bool _previewAllowed = true;
  bool _retaking = false;
  LoomCallSessionController? _calls;
  bool _video = false;
  bool _held = false;
  Offset _origin = Offset.zero;
  @override
  void initState() {
    super.initState();
    _previewMotion = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
      reverseDuration: const Duration(milliseconds: 180),
    );
    _audio = VoiceDraftController(_NativeVoiceBackend())..addListener(_changed);
    _camera = _VideoNoteBackend();
    _videoDraft = VoiceDraftController(
      _camera,
      maxDuration: const Duration(seconds: 60),
    )..addListener(_changed);
    widget.controller.addListener(_changed);
    WidgetsBinding.instance.addObserver(this);
    LoomAppLock.instance.addListener(_locked);
  }

  void _changed() {
    if (mounted) {
      final showPreview =
          _previewAllowed && _videoDraft.active && !LoomAppLock.instance.locked;
      if (showPreview &&
          (!_overlay.isShowing ||
              _previewMotion.status == AnimationStatus.reverse ||
              _previewMotion.status == AnimationStatus.dismissed)) {
        final opening = !_overlay.isShowing;
        if (opening) _overlay.show();
        if (LoomAccessibility.fromContext(context).reduceMotion) {
          _previewMotion.value = 1;
        } else {
          unawaited(_previewMotion.forward(from: opening ? 0 : null));
        }
      }
      if (!showPreview && _overlay.isShowing) {
        if (LoomAppLock.instance.locked) {
          _overlay.hide();
        } else {
          unawaited(
            _previewMotion.reverse().then((_) {
              if (mounted && !_videoDraft.active && _overlay.isShowing) {
                _overlay.hide();
              }
            }),
          );
        }
      }
      // Native camera textures animate independently. Amplitude callbacks do
      // not need to rebuild the composer and overlay many times each second.
      final visual =
          '${_voice.phase}:${_voice.duration.inSeconds}:${_voice.file?.path}:${_voice.error}:${widget.controller.text}';
      if (visual != _lastVisualState) {
        _lastVisualState = visual;
        setState(() {});
      }
    }
  }

  void _locked() {
    if (LoomAppLock.instance.locked) _cancel();
  }

  void _cancel({bool immediately = false}) {
    _previewAllowed = false;
    if (_overlay.isShowing) {
      if (immediately || LoomAppLock.instance.locked) {
        _overlay.hide();
      } else {
        unawaited(
          _previewMotion.reverse().then((_) {
            if (mounted && !_previewAllowed && _overlay.isShowing) {
              _overlay.hide();
            }
          }),
        );
      }
    }
    _held = false;
    _gestureEpoch++;
    unawaited(_closePreview());
    unawaited(_voice.cancel());
  }

  Future<void> _closePreview() async {
    final file = _voice.file;
    if (file != null && LoomPlaybackController.voice.isSource(file)) {
      await LoomPlaybackController.voice.close();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // A native permission dialog briefly makes the app inactive. Cancel an
    // in-progress capture there, but let permission initialization finish.
    final background =
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached;
    if ((background &&
            (_voice.capturing ||
                _voice.phase == VoicePhase.starting ||
                _retaking)) ||
        (state == AppLifecycleState.inactive && _voice.capturing)) {
      _cancel(immediately: true);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final calls = context
        .dependOnInheritedWidgetOfExactType<LoomCallSessionScope>()
        ?.notifier;
    if (_calls != calls) {
      _calls?.removeListener(_callChanged);
      _calls = calls;
      _calls?.addListener(_callChanged);
    }
    _callChanged();
    if (!TickerMode.valuesOf(context).enabled &&
        (_voice.capturing ||
            _voice.phase == VoicePhase.starting ||
            _retaking)) {
      _cancel();
    }
  }

  void _callChanged() {
    if ((_calls?.incomingCall != null ||
            _calls?.engine?.state.active == true) &&
        (_voice.capturing ||
            _voice.phase == VoicePhase.starting ||
            _retaking)) {
      _cancel();
    }
  }

  @override
  void didUpdateWidget(covariant _InlineVoiceComposer old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
    }
    // Parent sending changes are intentionally NOT cancellation signals.
  }

  void _begin(LongPressStartDetails details) {
    if (!widget.enabled ||
        widget.sending ||
        _retaking ||
        widget.controller.text.trim().isNotEmpty ||
        _voice.active) {
      return;
    }
    _previewAllowed = true;
    _gestureEpoch++;
    _held = true;
    _origin = details.globalPosition;
    widget.focusNode.unfocus();
    unawaited(HapticFeedback.selectionClick());
    unawaited(_voice.start());
  }

  void _move(LongPressMoveUpdateDetails details) {
    if (!_held || _voice.phase == VoicePhase.locked) return;
    final delta = details.globalPosition - _origin;
    final cancelDirection = Directionality.of(context) == TextDirection.rtl
        ? 1
        : -1;
    if (delta.dx * cancelDirection > 90) {
      _cancel();
      unawaited(HapticFeedback.selectionClick());
    } else if (delta.dy < -70) {
      _voice.lock();
      unawaited(HapticFeedback.selectionClick());
    }
  }

  Future<void> _sendVoice() async {
    if (_retaking) return;
    await _closePreview();
    if (!mounted || _retaking || LoomAppLock.instance.locked) return;
    await _voice.send(
      (file, peaks, duration) => _video
          ? widget.onVideoSend(file, duration)
          : widget.onVoiceSend(file, peaks, duration),
    );
  }

  @override
  void dispose() {
    _gestureEpoch++;
    widget.controller.removeListener(_changed);
    WidgetsBinding.instance.removeObserver(this);
    LoomAppLock.instance.removeListener(_locked);
    _calls?.removeListener(_callChanged);
    _audio.removeListener(_changed);
    _videoDraft.removeListener(_changed);
    unawaited(_closePreview());
    _audio.dispose();
    _videoDraft.dispose();
    _previewMotion.dispose();
    super.dispose();
  }

  Widget _recordingOverlay(BuildContext context) {
    final media = MediaQuery.of(context);
    final size = media.size;
    final overlayBox = Overlay.of(context).context.findRenderObject();
    var source =
        LoomOrigin.of(_recordActionKey.currentContext) ??
        Rect.fromCenter(center: _origin, width: 48, height: 48);
    if (overlayBox is RenderBox) {
      source = overlayBox.globalToLocal(source.topLeft) & source.size;
    }
    final bottom = source.top - 16;
    final available = Rect.fromLTRB(
      16,
      media.padding.top + 16,
      size.width - 16,
      math.max(media.padding.top + 17, bottom),
    );
    final controlsHeight = media.textScaler.scale(14) * 4 + 56;
    final previewSize = LoomVideoNoteGeometry.circularPreviewSize(
      Size(available.width, math.max(1, available.height - controlsHeight)),
    );
    final destination = Rect.fromCenter(
      center: available.center,
      width: math.min(440, available.width),
      height: math.min(available.height, previewSize.height + controlsHeight),
    );
    final camera = _camera.camera;
    final alternateLens = _camera.cameraSelection.alternateLens;
    final capturing = _voice.capturing;
    return Positioned.fill(
      child: Stack(
        children: [
          Positioned.fill(
            bottom: math.max(0, size.height - bottom),
            child: IgnorePointer(
              child: FadeTransition(
                opacity: _previewMotion,
                child: ColoredBox(color: Colors.black.withValues(alpha: .24)),
              ),
            ),
          ),
          LoomContainerTransform(
            animation: _previewMotion,
            origin: source,
            destination: destination,
            child: Material(
              color: Colors.transparent,
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    SizedBox(
                      width: previewSize.width,
                      height: previewSize.height,
                      child: LoomCircularVideoPreview(
                        diameter: previewSize.width,
                        progress: capturing
                            ? _voice.duration.inMilliseconds /
                                  const Duration(seconds: 60).inMilliseconds
                            : null,
                        child: !_previewAllowed
                            ? const SizedBox.shrink()
                            : _voice.file != null
                            ? _LocalVideoPreview(
                                file: _voice.file!,
                                round: true,
                                active: _voice.phase == VoicePhase.draft,
                              )
                            : camera?.value.isInitialized == true
                            ? FittedBox(
                                fit: BoxFit.cover,
                                child: SizedBox(
                                  width: 480,
                                  height: 480 * camera!.value.aspectRatio,
                                  child: CameraPreview(camera),
                                ),
                              )
                            : const ColoredBox(
                                color: Colors.black,
                                child: Center(
                                  child: CircularProgressIndicator(),
                                ),
                              ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      child: Semantics(
                        liveRegion: true,
                        child: Text(
                          _voice.phase == VoicePhase.starting
                              ? tr(
                                  context,
                                  'Preparing camera…',
                                  'آماده‌سازی دوربین…',
                                )
                              : _voice.phase == VoicePhase.stopping
                              ? tr(
                                  context,
                                  'Preparing video…',
                                  'آماده‌سازی ویدیو…',
                                )
                              : _voice.phase == VoicePhase.draft
                              ? tr(
                                  context,
                                  'Review before sending',
                                  'قبل از ارسال بازبینی کنید',
                                )
                              : '${capturing ? tr(context, 'Recording', 'در حال ضبط') : tr(context, 'Video draft', 'پیش‌نویس ویدیو')} · ${mediaTime(_voice.duration)}',
                          textAlign: TextAlign.center,
                          maxLines: 2,
                        ),
                      ),
                    ),
                    if (_voice.phase == VoicePhase.draft)
                      Wrap(
                        alignment: WrapAlignment.center,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          TextButton(
                            onPressed: _retaking ? null : () => _retake(),
                            child: Text(tr(context, 'Retake', 'ضبط دوباره')),
                          ),
                          if (alternateLens != null)
                            TextButton.icon(
                              onPressed: _retaking
                                  ? null
                                  : () => _retake(lens: alternateLens),
                              icon: const Icon(LoomIcons.cameraswitch_outlined),
                              label: Text(
                                alternateLens == CameraLensDirection.back
                                    ? tr(
                                        context,
                                        'Retake with rear camera',
                                        'ضبط دوباره با دوربین پشت',
                                      )
                                    : tr(
                                        context,
                                        'Retake with front camera',
                                        'ضبط دوباره با دوربین جلو',
                                      ),
                              ),
                            ),
                          TextButton(
                            onPressed: _cancel,
                            child: Text(tr(context, 'Discard', 'حذف')),
                          ),
                          FilledButton(
                            onPressed: _retaking
                                ? null
                                : () => unawaited(_sendVoice()),
                            child: Text(tr(context, 'Send', 'ارسال')),
                          ),
                        ],
                      )
                    else if (capturing)
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          TextButton(
                            onPressed: _cancel,
                            child: Text(tr(context, 'Cancel', 'لغو')),
                          ),
                          if (_voice.phase == VoicePhase.recording)
                            TextButton(
                              onPressed: _voice.lock,
                              child: Text(tr(context, 'Lock', 'قفل')),
                            ),
                          TextButton(
                            onPressed: () => unawaited(_voice.stop()),
                            child: Text(tr(context, 'Stop', 'توقف')),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  bool _canRetake(int epoch) {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    return mounted &&
        epoch == _gestureEpoch &&
        widget.enabled &&
        !widget.sending &&
        !LoomAppLock.instance.locked &&
        _calls?.incomingCall == null &&
        _calls?.engine?.state.active != true &&
        lifecycle != AppLifecycleState.paused &&
        lifecycle != AppLifecycleState.hidden &&
        lifecycle != AppLifecycleState.detached;
  }

  Future<void> _retake({CameraLensDirection? lens}) async {
    if (_retaking || !_video || _voice.phase != VoicePhase.draft) return;
    final epoch = _gestureEpoch;
    if (!_canRetake(epoch)) return;
    setState(() => _retaking = true);
    try {
      await _closePreview();
      if (!_canRetake(epoch) || _voice.phase != VoicePhase.draft) return;
      await _voice.cancel();
      if (!_canRetake(epoch)) return;
      if (lens != null) _camera.cameraSelection.preferredLens = lens;
      _previewAllowed = true;
      await _voice.start(locked: true);
    } finally {
      if (mounted) setState(() => _retaking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final phase = _voice.phase;
    final busy =
        _retaking ||
        phase == VoicePhase.starting ||
        phase == VoicePhase.stopping ||
        phase == VoicePhase.sending;
    final hasText = widget.controller.text.trim().isNotEmpty;
    final active = _voice.active;
    final p = context.loom;
    final tooltip = phase == VoicePhase.locked
        ? tr(context, 'Stop and review', 'توقف و بازبینی')
        : phase == VoicePhase.draft || hasText
        ? tr(context, 'Send', 'ارسال')
        : !LoomMediaCapabilities.cameraCapture
        ? tr(context, 'Click to record voice', 'برای ضبط صدا کلیک کنید')
        : _video
        ? tr(
            context,
            'Hold to record video · slide up to lock · tap for voice',
            'برای ضبط ویدیو نگه دارید · بالا بکشید تا قفل شود · برای صدا بزنید',
          )
        : tr(
            context,
            'Hold to record · slide up to lock · tap for video',
            'برای ضبط نگه دارید · بالا بکشید تا قفل شود · برای ویدیو بزنید',
          );
    Widget? input;
    if (active) {
      if (phase == VoicePhase.draft || phase == VoicePhase.sending) {
        input = Row(
          children: [
            IconButton(
              tooltip: tr(context, 'Delete recording', 'حذف ضبط'),
              onPressed: busy ? null : _cancel,
              icon: const Icon(LoomIcons.delete_outline),
            ),
            Expanded(
              child: _video
                  ? Text(
                      '${tr(context, 'Video draft · tap preview', 'پیش‌نویس ویدیو · پیش‌نمایش را بزنید')} · ${mediaTime(_voice.duration)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    )
                  : _voice.file == null
                  ? const SizedBox.shrink()
                  : LoomAudioTile(
                      file: _voice.file!,
                      title: tr(context, 'Voice draft', 'پیش‌نویس صوتی'),
                      compact: true,
                      waveform: _voice.waveform,
                      duration: _voice.duration,
                    ),
            ),
          ],
        );
      } else {
        input = Row(
          children: [
            IconButton(
              tooltip: tr(context, 'Cancel recording', 'لغو ضبط'),
              onPressed: _cancel,
              icon: const Icon(LoomIcons.close),
            ),
            Icon(LoomIcons.mic, size: 18, color: p.critical),
            const SizedBox(width: 4),
            Text(mediaTime(_voice.duration), textDirection: TextDirection.ltr),
            const SizedBox(width: 6),
            Expanded(
              child: phase == VoicePhase.locked
                  ? TextButton.icon(
                      onPressed: () => unawaited(_voice.stop()),
                      icon: const Icon(LoomIcons.stop),
                      label: Text(tr(context, 'Stop', 'توقف')),
                    )
                  : Text(
                      tr(
                        context,
                        '‹ Slide to cancel · ↑ Lock',
                        'لغو با کشیدن · ↑ قفل',
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
            ),
          ],
        );
      }
    }
    return OverlayPortal(
      controller: _overlay,
      overlayChildBuilder: (context) => _recordingOverlay(context),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_voice.error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Text(
                tr(
                  context,
                  _voice.error == 'send_failed'
                      ? 'Not sent. Your voice draft is kept; tap Send to retry.'
                      : _video
                      ? 'Video recording unavailable or too short. Check camera and microphone permissions.'
                      : 'Recording unavailable or too short. Check microphone permission and retry.',
                  _voice.error == 'send_failed'
                      ? 'ارسال نشد؛ پیش‌نویس صوتی حفظ شد. دوباره ارسال کنید.'
                      : _video
                      ? 'ضبط ویدیو ممکن نشد یا کوتاه بود؛ مجوز دوربین و میکروفون را بررسی کنید.'
                      : 'ضبط ممکن نشد یا خیلی کوتاه بود؛ مجوز میکروفون را بررسی کنید.',
                ),
                style: Theme.of(
                  context,
                ).textTheme.labelSmall?.copyWith(color: p.critical),
              ),
            ),
          LoomGlassComposer(
            onContentInserted: widget.onContentInserted,
            controller: widget.controller,
            focusNode: widget.focusNode,
            enabled: widget.enabled && !active && !_retaking,
            sending: widget.sending,
            hintText: tr(context, 'Message', 'پیام'),
            attachTooltip: tr(context, 'Attach', 'پیوست'),
            voiceTooltip: tooltip,
            sendTooltip: tr(context, 'Send', 'ارسال'),
            attachmentKey: _attachmentKey,
            onAttach: active || _retaking
                ? null
                : () {
                    widget.onAttachmentOrigin?.call(
                      LoomOrigin.of(_attachmentKey.currentContext),
                    );
                    widget.onAttach?.call();
                  },
            onSend: widget.onSend,
            inputOverride: input,
            actionOverride: Tooltip(
              key: _recordActionKey,
              message: tooltip,
              child: Semantics(
                button: true,
                label: tooltip,
                onLongPress:
                    widget.enabled &&
                        !widget.sending &&
                        !_retaking &&
                        !active &&
                        !hasText
                    ? () {
                        _previewAllowed = true;
                        unawaited(_voice.start(locked: true));
                      }
                    : null,
                child: LoomHoldRecordAction(
                  onStart: _begin,
                  onMove: _move,
                  onEnd: (_) async {
                    final epoch = _gestureEpoch;
                    final held = _held;
                    _held = false;
                    if (!held || _voice.phase == VoicePhase.locked) return;
                    await _voice.release();
                    if (mounted && epoch == _gestureEpoch) {
                      // Releasing stops into a local preview. Send is always
                      // explicit so a user can inspect or discard the recording.
                      _changed();
                    }
                  },
                  onCancel: () {
                    if (_held) _cancel();
                  },
                  onTap: !widget.enabled || busy || widget.sending
                      ? null
                      : () {
                          if (phase == VoicePhase.draft) {
                            unawaited(_sendVoice());
                          } else if (phase == VoicePhase.locked) {
                            unawaited(_voice.stop());
                          } else if (!active && hasText) {
                            widget.onSend?.call();
                          } else if (!active &&
                              LoomMediaCapabilities.cameraCapture) {
                            unawaited(HapticFeedback.selectionClick());
                            setState(() => _video = !_video);
                          } else if (!active) {
                            unawaited(_voice.start(locked: true));
                          }
                        },
                  child: LoomPressable(
                    enabled: widget.enabled && !busy && !widget.sending,
                    child: AnimatedContainer(
                      duration:
                          LoomAccessibility.fromContext(context).reduceMotion
                          ? Duration.zero
                          : const Duration(milliseconds: 220),
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: _voice.capturing ? p.critical : p.primary,
                        shape: BoxShape.circle,
                      ),
                      child: busy || widget.sending
                          ? Padding(
                              padding: const EdgeInsets.all(14),
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: p.onPrimary,
                              ),
                            )
                          : LoomComposerMorph(
                              child: Icon(
                                phase == VoicePhase.locked
                                    ? LoomIcons.stop
                                    : phase == VoicePhase.draft || hasText
                                    ? LoomIcons.arrow_upward_rounded
                                    : _video
                                    ? LoomIcons.videocam_rounded
                                    : LoomIcons.mic_rounded,
                                key: ValueKey(
                                  phase == VoicePhase.locked
                                      ? 'stop'
                                      : phase == VoicePhase.draft || hasText
                                      ? 'send'
                                      : _video
                                      ? 'video'
                                      : 'voice',
                                ),
                                color: p.onPrimary,
                              ),
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
  }
}
