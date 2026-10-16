import 'dart:async';
import 'dart:typed_data';
import 'package:loom_crypto_bridge/loom_crypto_bridge.dart';
import 'package:loom_design/loom_design.dart';
import 'package:flutter/material.dart';
import '../../../app/loom_strings.dart';
import '../application/groups_controller.dart';
import 'group_avatar.dart';
import 'group_photo_picker.dart';

class LoomGroupPhotoEditor extends StatefulWidget {
  const LoomGroupPhotoEditor({
    required this.groups,
    required this.groupId,
    required this.title,
    this.pickPhoto,
    super.key,
  });
  final LoomGroupsController groups;
  final String groupId, title;
  final Future<Uint8List?> Function()? pickPhoto;
  @override
  State<LoomGroupPhotoEditor> createState() => _LoomGroupPhotoEditorState();
}

class _LoomGroupPhotoEditorState extends State<LoomGroupPhotoEditor> {
  Uint8List? _draft;
  bool _busy = false, _changed = false, _allowPop = false, _confirming = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    LoomAppLock.instance.addListener(_lockChanged);
    final current = widget.groups.groupPhoto(widget.groupId);
    _draft = current == null ? null : Uint8List.fromList(current);
  }

  void _clear() {
    final old = _draft;
    _draft = null;
    if (old != null) {
      unawaited(MemoryImage(old).evict());
      old.fillRange(0, old.length, 0);
    }
  }

  void _lockChanged() {
    if (!LoomAppLock.instance.locked || !mounted) return;
    setState(() {
      _clear();
      _changed = false;
      _error = null;
    });
  }

  @override
  void dispose() {
    LoomAppLock.instance.removeListener(_lockChanged);
    _clear();
    super.dispose();
  }

  Future<void> _pick() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await (widget.pickPhoto ?? pickLoomGroupPhoto)();
      if (!mounted || LoomAppLock.instance.locked) {
        result?.fillRange(0, result.length, 0);
        return;
      }
      if (result != null) {
        setState(() {
          _clear();
          _draft = result;
          _changed = true;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = tr(
            context,
            'Could not prepare this photo. Choose an image smaller than 8 MiB.',
            'تصویر آماده نشد. تصویری کوچک‌تر از ۸ مگابایت انتخاب کنید.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancel() async {
    if (_busy || _confirming) return;
    if (_changed) {
      _confirming = true;
      final discard = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(
            tr(
              context,
              'Discard photo change?',
              'تغییر تصویر کنار گذاشته شود؟',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(tr(context, 'Keep editing', 'ادامهٔ ویرایش')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(tr(context, 'Discard', 'کنار گذاشتن')),
            ),
          ],
        ),
      );
      _confirming = false;
      if (!mounted || discard != true) return;
    }
    _close();
  }

  void _close() {
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.pop(context);
    });
  }

  Future<void> _save() async {
    if (_busy || !_changed) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    var success = false;
    try {
      success = await widget.groups.setGroupPhoto(widget.groupId, _draft);
    } catch (_) {
      /* Keep draft and show the same recoverable error. */
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (!success) {
        _error = tr(
          context,
          'Photo was not saved. Your selection is kept here; try again.',
          'تصویر ذخیره نشد. انتخاب شما اینجا حفظ شده؛ دوباره تلاش کنید.',
        );
      }
    });
    if (success) _close();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: _allowPop || (!_busy && !_changed),
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) unawaited(_cancel());
    },
    child: AlertDialog(
      scrollable: true,
      title: Text(tr(context, 'Group photo', 'تصویر گروه')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          LoomGroupPhotoAvatar(
            label: widget.title,
            size: LoomSizing.profileAvatar,
            photo: _draft,
          ),
          const SizedBox(height: LoomSpacing.md),
          Text(
            tr(
              context,
              'Shared only with group members. New members can see the current photo.',
              'فقط با اعضای گروه به اشتراک گذاشته می‌شود. اعضای جدید تصویر فعلی را می‌بینند.',
            ),
          ),
          const SizedBox(height: LoomSpacing.sm),
          Wrap(
            alignment: WrapAlignment.center,
            children: [
              TextButton.icon(
                onPressed: _busy ? null : _pick,
                icon: const Icon(LoomIcons.photo_library_outlined),
                label: Text(tr(context, 'Choose photo', 'انتخاب تصویر')),
              ),
              if (_draft != null)
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => setState(() {
                          _clear();
                          _changed = true;
                        }),
                  child: Text(tr(context, 'Remove photo', 'حذف تصویر')),
                ),
            ],
          ),
          if (_busy) const LinearProgressIndicator(),
          if (_error != null) LoomFeedbackSurface(message: _error!),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : _cancel,
          child: Text(tr(context, 'Cancel', 'لغو')),
        ),
        FilledButton(
          onPressed: _busy || !_changed ? null : _save,
          child: Text(tr(context, 'Save', 'ذخیره')),
        ),
      ],
    ),
  );
}
