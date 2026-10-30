import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:loom_crypto_bridge/loom_crypto_bridge.dart';
import 'package:loom_design/loom_design.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app/loom_strings.dart';
import '../application/playback_controller.dart';
import '../application/media_capabilities.dart';
import 'circular_video_preview.dart';

class LoomCameraCapture {
  const LoomCameraCapture(this.file, this.kind);
  final File file;
  final String kind;
}

/// Real camera preview and capture: never launches the phone's camera app.
class LoomCameraScreen extends StatefulWidget {
  const LoomCameraScreen({
    this.video = false,
    this.videoNote = false,
    super.key,
  });
  final bool video, videoNote;
  @override
  State<LoomCameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<LoomCameraScreen>
    with WidgetsBindingObserver {
  CameraController? _camera;
  List<CameraDescription> _devices = const [];
  bool _video = false;
  bool _front = false, _busy = false, _recording = false;
  String? _error;
  Timer? _timer;
  int _seconds = 0, _epoch = 0;
  File? _capture;
  bool _returned = false, _disposing = false;
  bool _held = false, _heldLocked = false, _heldCancelled = false;
  Offset _holdOrigin = Offset.zero;
  Future<void> _cancelRecording() async {
    _held = false;
    _heldCancelled = true;
    await _release();
    if (mounted && !LoomAppLock.instance.locked) await _initialize();
  }

  Future<void> _beginHeld(LongPressStartDetails details) async {
    if (!_video || _recording || _busy || _camera == null) return;
    _held = true;
    _heldLocked = false;
    _heldCancelled = false;
    _holdOrigin = details.globalPosition;
    await _shutter();
    if (!mounted) return;
    if (_heldCancelled) {
      await _cancelRecording();
    } else if (!_held && !_heldLocked && _recording) {
      await _shutter();
    }
  }

  void _moveHeld(LongPressMoveUpdateDetails details) {
    if (!_held || _heldLocked || _heldCancelled) return;
    final delta = details.globalPosition - _holdOrigin;
    final cancelDirection = Directionality.of(context) == TextDirection.rtl
        ? 1
        : -1;
    if (delta.dx * cancelDirection > 90) {
      _heldCancelled = true;
      if (!_busy) unawaited(_cancelRecording());
    } else if (delta.dy < -70) {
      setState(() => _heldLocked = true);
    }
  }

  void _endHeld() {
    _held = false;
    if (!_heldLocked && !_heldCancelled && _recording && !_busy) {
      unawaited(_shutter());
    }
  }

  @override
  void initState() {
    super.initState();
    _front = widget.videoNote;
    _video = widget.video || widget.videoNote;
    WidgetsBinding.instance.addObserver(this);
    LoomAppLock.instance.addListener(_locked);
    unawaited(_initialize());
  }

  void _locked() {
    if (LoomAppLock.instance.locked) {
      unawaited(_release());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_camera == null && !LoomAppLock.instance.locked) {
        unawaited(_initialize());
      }
    } else {
      unawaited(_release());
    }
  }

  Future<void> _initialize() async {
    if (!LoomMediaCapabilities.cameraCapture) {
      setState(() => _error = 'capture_not_supported');
      return;
    }
    if (_busy || LoomAppLock.instance.locked) {
      return;
    }
    final epoch = ++_epoch;
    setState(() => _busy = true);
    CameraController? camera;
    try {
      await LoomPlaybackController.pauseAll();
      _devices = await availableCameras();
      if (_devices.isEmpty) {
        throw StateError('no_camera');
      }
      final direction = _front
          ? CameraLensDirection.front
          : CameraLensDirection.back;
      final device =
          _devices.where((d) => d.lensDirection == direction).firstOrNull ??
          _devices.first;
      camera = CameraController(
        device,
        ResolutionPreset.high,
        enableAudio: _video,
      );
      await camera.initialize();
      if (!mounted || epoch != _epoch || LoomAppLock.instance.locked) {
        await camera.dispose();
        return;
      }
      _camera = camera;
      _error = null;
    } catch (failure) {
      try {
        await camera?.dispose();
      } catch (_) {}
      if (mounted && epoch == _epoch) {
        _error = failure is CameraException
            ? failure.code
            : 'camera_unavailable';
      }
    } finally {
      if (mounted && epoch == _epoch) {
        setState(() => _busy = false);
      }
    }
  }

  /// Deep-link into the OS app-settings page after a permission denial.
  Future<void> _openSystemSettings() async {
    try {
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        await launchUrl(
          Uri.parse('app-settings:'),
          mode: LaunchMode.externalApplication,
        );
      } else {
        await launchUrl(
          Uri.parse('package:app.loom.messenger'),
          mode: LaunchMode.externalApplication,
        );
      }
    } catch (_) {
      // The OS may refuse the deep link; the retry button still works.
    }
  }

  Future<void> _release() async {
    ++_epoch;
    _timer?.cancel();
    final camera = _camera;
    _camera = null;
    if (camera != null) {
      try {
        if (camera.value.isRecordingVideo) {
          final output = await camera.stopVideoRecording();
          await File(output.path).delete();
        }
      } catch (_) {}
      try {
        await camera.dispose();
      } catch (_) {}
    }
    if (mounted && !_disposing) {
      setState(() {
        _busy = false;
        _recording = false;
        _seconds = 0;
      });
    }
  }

  Future<void> _switch() async {
    if (_busy || _recording) {
      return;
    }
    await _release();
    _front = !_front;
    if (mounted) {
      await _initialize();
    }
  }

  Future<void> _flash() async {
    final camera = _camera;
    if (camera == null || _busy) {
      return;
    }
    try {
      await camera.setFlashMode(
        camera.value.flashMode == FlashMode.off
            ? FlashMode.torch
            : FlashMode.off,
      );
      if (mounted) {
        setState(() {});
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              tr(context, 'Flash unavailable', 'فلش در دسترس نیست'),
            ),
          ),
        );
      }
    }
  }

  Future<void> _shutter() async {
    final camera = _camera;
    if (camera == null || _busy || LoomAppLock.instance.locked) {
      return;
    }
    final epoch = _epoch;
    setState(() => _busy = true);
    try {
      if (_video) {
        if (!_recording) {
          await camera.startVideoRecording();
          if (!mounted || epoch != _epoch || LoomAppLock.instance.locked) {
            return;
          }
          _recording = true;
          _seconds = 0;
          _timer = Timer.periodic(const Duration(seconds: 1), (_) {
            if (!mounted || !_recording) {
              return;
            }
            setState(() => _seconds++);
            if (_seconds >= 60) {
              unawaited(_shutter());
            }
          });
          return;
        }
        _timer?.cancel();
        final output = await camera.stopVideoRecording();
        _recording = false;
        _capture = File(output.path);
      } else {
        final output = await camera.takePicture();
        _capture = File(output.path);
      }
      if (!mounted || epoch != _epoch || LoomAppLock.instance.locked) {
        try {
          await _capture?.delete();
        } catch (_) {}
        return;
      }
      _returned = true;
      Navigator.pop(
        context,
        LoomCameraCapture(
          _capture!,
          widget.videoNote
              ? 'video_note'
              : _video
              ? 'video'
              : 'image',
        ),
      );
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'capture_failed');
      }
    } finally {
      if (mounted && epoch == _epoch) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  void dispose() {
    _disposing = true;
    WidgetsBinding.instance.removeObserver(this);
    LoomAppLock.instance.removeListener(_locked);
    _timer?.cancel();
    unawaited(_release());
    if (!_returned) {
      unawaited(_capture?.delete().catchError((Object _) => _capture!));
    }
    super.dispose();
  }

  Future<void> _pickExistingCapture() async {
    setState(() => _busy = true);
    Directory? temporary;
    try {
      final file = await openFile(
        acceptedTypeGroups: [
          XTypeGroup(
            label: _video ? 'Video' : 'Photos',
            extensions: _video
                ? ['mp4', 'mov', 'mkv', 'webm']
                : ['jpg', 'jpeg', 'png', 'webp'],
          ),
        ],
      );
      if (file == null || !mounted || LoomAppLock.instance.locked) return;
      // Capture consumers may delete this private copy, never the user's source.
      temporary = await Directory.systemTemp.createTemp('loom_capture_');
      final copy = await File(file.path).copy('${temporary.path}/${file.name}');
      if (!mounted || LoomAppLock.instance.locked) return;
      _returned = true;
      Navigator.pop(
        context,
        LoomCameraCapture(copy, _video ? 'video' : 'image'),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              tr(
                context,
                'Could not open this file. Try again.',
                'فایل باز نشد؛ دوباره تلاش کنید.',
              ),
            ),
          ),
        );
      }
    } finally {
      if (!_returned && temporary != null) {
        try {
          await temporary.delete(recursive: true);
        } catch (_) {}
      }
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!LoomMediaCapabilities.cameraCapture) {
      return Scaffold(
        appBar: LoomGlassAppBar(
          title: Text(tr(context, 'Choose media', 'انتخاب مدیا')),
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(LoomIcons.movie_outlined, size: 48),
                const SizedBox(height: 16),
                Text(
                  tr(
                    context,
                    'Camera capture is unavailable on this platform. Choose an existing file.',
                    'ثبت تصویر با دوربین روی این پلتفرم در دسترس نیست. یک فایل موجود انتخاب کنید.',
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  icon: const Icon(LoomIcons.folder_open),
                  label: Text(tr(context, 'Choose file', 'انتخاب فایل')),
                  onPressed: _busy ? null : _pickExistingCapture,
                ),
                if (Platform.isWindows)
                  TextButton(
                    onPressed: () =>
                        launchUrl(Uri.parse('ms-settings:privacy-webcam')),
                    child: Text(
                      tr(
                        context,
                        'Windows camera privacy settings',
                        'تنظیمات حریم خصوصی دوربین ویندوز',
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    }
    return Theme(
      data: LoomTheme.dark(),
      child: Builder(builder: _buildCapture),
    );
  }

  Widget _buildCapture(BuildContext context) {
    final camera = _camera;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: LoomGlassAppBar(
        title: Text(
          tr(
            context,
            widget.videoNote
                ? 'Video message'
                : _video
                ? 'Record video'
                : 'Camera',
            widget.videoNote
                ? 'ویدیو مسیج'
                : _video
                ? 'ضبط ویدیو'
                : 'دوربین',
          ),
        ),
        actions: [
          IconButton(
            tooltip: tr(context, 'Flash', 'فلش'),
            onPressed: camera == null ? null : _flash,
            icon: Icon(
              camera?.value.flashMode == FlashMode.torch
                  ? LoomIcons.flash_on
                  : LoomIcons.flash_off,
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: camera == null
                  ? (_busy
                        ? const CircularProgressIndicator()
                        : Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                _error == 'CameraAccessDenied'
                                    ? tr(
                                        context,
                                        'Camera access is denied. Allow the camera for Loom in system settings.',
                                        'دسترسی دوربین رد شده؛ در تنظیمات سیستم به لوم اجازهٔ دوربین بدهید.',
                                      )
                                    : tr(
                                        context,
                                        'Camera unavailable. Check permissions.',
                                        'دوربین در دسترس نیست؛ مجوزها را بررسی کنید.',
                                      ),
                                textAlign: TextAlign.center,
                              ),
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  TextButton(
                                    onPressed: _initialize,
                                    child: Text(
                                      tr(context, 'Retry', 'تلاش مجدد'),
                                    ),
                                  ),
                                  if (_error == 'CameraAccessDenied' &&
                                      !kIsWeb &&
                                      (defaultTargetPlatform ==
                                              TargetPlatform.android ||
                                          defaultTargetPlatform ==
                                              TargetPlatform.iOS))
                                    TextButton(
                                      key: const ValueKey(
                                        'open-camera-settings',
                                      ),
                                      onPressed: () => unawaited(
                                        _openSystemSettings(),
                                      ),
                                      child: Text(
                                        tr(
                                          context,
                                          'Open settings',
                                          'باز کردن تنظیمات',
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ],
                          ))
                  : widget.videoNote
                  ? LayoutBuilder(
                      builder: (context, bounds) => Center(
                        child: LoomCircularVideoPreview(
                          diameter: (bounds.biggest.shortestSide - 24)
                              .clamp(1.0, 420.0)
                              .toDouble(),
                          progress: _recording ? _seconds / 60 : null,
                          child: ClipRect(
                            child: FittedBox(
                              fit: BoxFit.cover,
                              child: SizedBox(
                                width: camera.value.previewSize!.height,
                                height: camera.value.previewSize!.width,
                                child: CameraPreview(camera),
                              ),
                            ),
                          ),
                        ),
                      ),
                    )
                  : AspectRatio(
                      aspectRatio:
                          MediaQuery.orientationOf(context) ==
                              Orientation.portrait
                          ? 1 / camera.value.aspectRatio
                          : camera.value.aspectRatio,
                      child: CameraPreview(camera),
                    ),
            ),
          ),
          if (_error != null && camera != null)
            Text(
              tr(
                context,
                'Capture failed; try again.',
                'ثبت تصویر ناموفق بود؛ دوباره تلاش کنید.',
              ),
            ),
          if (_video && _recording)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                _heldLocked
                    ? tr(
                        context,
                        'Recording locked · tap Stop to preview',
                        'ضبط قفل شد؛ برای پیش‌نمایش توقف را بزنید',
                      )
                    : tr(
                        context,
                        'Slide to cancel · slide up to lock',
                        'با کشیدن لغو کنید · برای قفل بالا بکشید',
                      ),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  IconButton(
                    tooltip: _recording
                        ? tr(context, 'Cancel recording', 'لغو ضبط')
                        : tr(context, 'Switch camera', 'تعویض دوربین'),
                    onPressed: _recording && !_busy
                        ? _cancelRecording
                        : _devices.length > 1 && !_recording && !_busy
                        ? _switch
                        : null,
                    icon: Icon(
                      _recording
                          ? LoomIcons.close_rounded
                          : LoomIcons.cameraswitch_outlined,
                    ),
                  ),
                  Semantics(
                    button: true,
                    label: tr(
                      context,
                      _recording ? 'Stop recording' : 'Capture',
                      _recording ? 'توقف ضبط' : 'ثبت',
                    ),
                    child: GestureDetector(
                      onLongPressStart: _video ? _beginHeld : null,
                      onLongPressMoveUpdate: _video ? _moveHeld : null,
                      onLongPressEnd: _video ? (_) => _endHeld() : null,
                      onLongPressCancel: _video
                          ? () {
                              if (_held) unawaited(_cancelRecording());
                            }
                          : null,
                      onTap: camera != null && !_busy ? _shutter : null,
                      child: Container(
                        width: 76,
                        height: 76,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: context.loom.primary,
                            width: 3,
                          ),
                        ),
                        child: Center(
                          child: Container(
                            width: _recording ? 30 : 60,
                            height: _recording ? 30 : 60,
                            decoration: BoxDecoration(
                              color: _video
                                  ? context.loom.critical
                                  : context.loom.primary,
                              borderRadius: BorderRadius.circular(
                                _recording ? 8 : 30,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (!widget.videoNote && !_recording)
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () async {
                              await _release();
                              if (!mounted) return;
                              _video = !_video;
                              await _initialize();
                            },
                      child: Text(
                        tr(
                          context,
                          _video ? 'Video ▾' : 'Photo ▾',
                          _video ? 'ویدیو ▾' : 'عکس ▾',
                        ),
                      ),
                    )
                  else
                    Text(
                      _recording
                          ? '${_seconds ~/ 60}:${(_seconds % 60).toString().padLeft(2, '0')}'
                          : tr(
                              context,
                              _video ? 'Video' : 'Photo',
                              _video ? 'ویدیو' : 'عکس',
                            ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
