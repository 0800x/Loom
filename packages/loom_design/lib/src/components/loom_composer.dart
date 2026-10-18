import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../loom_accessibility.dart';
import '../loom_glass.dart';
import '../loom_icons.dart';
import '../loom_interactions.dart';
import '../loom_theme.dart';
import '../loom_tokens.dart';

/// Physical desktop keys only; mobile soft keyboards keep multiline editing.
/// Repeat events are consumed so holding Enter cannot queue duplicate sends.
class LoomComposerKeyboard extends StatefulWidget {
  const LoomComposerKeyboard({
    required this.controller,
    required this.onSend,
    required this.child,
    this.enabled = true,
    super.key,
  });

  final TextEditingController controller;
  final VoidCallback onSend;
  final Widget child;
  final bool enabled;

  @override
  State<LoomComposerKeyboard> createState() => _ComposerKeyboardState();
}

class _ComposerEnterIntent extends Intent {
  const _ComposerEnterIntent(this.newline);
  final bool newline;
}

class _ComposerShortcutManager extends ShortcutManager {
  _ComposerShortcutManager(this.handleEnter);
  final KeyEventResult Function(KeyEvent) handleEnter;

  @override
  KeyEventResult handleKeypress(BuildContext context, KeyEvent event) =>
      handleEnter(event);
}

class _ComposerKeyboardState extends State<LoomComposerKeyboard> {
  late final _manager = _ComposerShortcutManager(_handleEnter);

  KeyEventResult _handleEnter(KeyEvent event) {
    if (event.logicalKey != LogicalKeyboardKey.enter &&
        event.logicalKey != LogicalKeyboardKey.numpadEnter) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    final desktop = !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.linux ||
            defaultTargetPlatform == TargetPlatform.macOS);
    final value = widget.controller.value;
    if (keyboard.isAltPressed ||
        (!desktop && !keyboard.isControlPressed && !keyboard.isMetaPressed) ||
        (value.composing.isValid && !value.composing.isCollapsed)) {
      return KeyEventResult.ignored;
    }
    if (event is KeyDownEvent) {
      final focusedContext = FocusManager.instance.primaryFocus?.context;
      if (focusedContext != null) {
        Actions.invoke(
          focusedContext,
          _ComposerEnterIntent(keyboard.isShiftPressed),
        );
      }
    }
    return KeyEventResult.handled;
  }

  void _enter(_ComposerEnterIntent intent) {
    if (intent.newline) {
      final value = widget.controller.value;
      final selection = value.selection.isValid
          ? value.selection
          : TextSelection.collapsed(offset: value.text.length);
      widget.controller.value = value.copyWith(
        text: value.text.replaceRange(selection.start, selection.end, '\n'),
        selection: TextSelection.collapsed(offset: selection.start + 1),
        composing: TextRange.empty,
      );
    } else if (widget.enabled && widget.controller.text.trim().isNotEmpty) {
      widget.onSend();
    }
  }

  @override
  void dispose() {
    _manager.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Shortcuts.manager(
        manager: _manager,
        child: Actions(
          actions: {
            _ComposerEnterIntent: CallbackAction<_ComposerEnterIntent>(
              onInvoke: (intent) {
                _enter(intent);
                return null;
              },
            ),
          },
          child: widget.child,
        ),
      );
}

class LoomGlassComposer extends StatefulWidget {
  const LoomGlassComposer({
    required this.hintText,
    required this.attachTooltip,
    required this.voiceTooltip,
    required this.sendTooltip,
    this.controller,
    this.focusNode,
    this.enabled = true,
    this.sending = false,
    this.onAttach,
    this.attachmentKey,
    this.onVoice,
    this.onSend,
    this.onSubmitted,
    this.onChanged,
    this.onContentInserted,
    this.inputOverride,
    this.actionOverride,
    super.key,
  });

  final Widget? inputOverride, actionOverride;
  final String hintText;
  final String attachTooltip;
  final String voiceTooltip;
  final String sendTooltip;
  final TextEditingController? controller;
  final FocusNode? focusNode;
  final bool enabled;
  final bool sending;
  final VoidCallback? onAttach;
  final Key? attachmentKey;
  final VoidCallback? onVoice;
  final VoidCallback? onSend;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;
  final ValueChanged<KeyboardInsertedContent>? onContentInserted;

  @override
  State<LoomGlassComposer> createState() => _LoomGlassComposerState();
}

class _LoomGlassComposerState extends State<LoomGlassComposer> {
  final _ownedController = TextEditingController();
  TextEditingController get _controller =>
      widget.controller ?? _ownedController;
  bool get _canSend =>
      widget.enabled &&
      !widget.sending &&
      widget.onSend != null &&
      _controller.text.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_changed);
  }

  @override
  void didUpdateWidget(covariant LoomGlassComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      (oldWidget.controller ?? _ownedController).removeListener(_changed);
      _controller.addListener(_changed);
    }
  }

  bool get _voiceMode =>
      _controller.text.trim().isEmpty && widget.onVoice != null;
  bool get _canVoice => widget.enabled && !widget.sending && _voiceMode;
  void _changed() => setState(() {});
  void _submit() {
    if (_canSend) {
      widget.onSend!();
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_changed);
    _ownedController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.loom;
    final reduceMotion = LoomAccessibility.fromContext(context).reduceMotion;
    return ConstrainedBox(
      constraints: const BoxConstraints(
        minHeight: LoomSizing.composerMinHeight,
      ),
      child: LoomGlassSurface(
        strength: LoomGlassStrength.standard,
        liveBackdrop: true,
        radius: 26,
        padding: const EdgeInsets.fromLTRB(4, 0, 2, 0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (widget.onAttach != null)
              IconButton(
                key: widget.attachmentKey,
                onPressed: widget.enabled ? widget.onAttach : null,
                icon: const Icon(LoomIcons.attach_file_rounded),
                color: p.textSecondary,
                tooltip: widget.attachTooltip,
              ),
            Expanded(
              child: AnimatedSize(
                duration: reduceMotion
                    ? Duration.zero
                    : const Duration(milliseconds: 200),
                curve: Curves.easeOutQuart,
                alignment: Alignment.bottomCenter,
                child: widget.inputOverride ??
                    LoomComposerKeyboard(
                      controller: _controller,
                      enabled: widget.enabled &&
                          !widget.sending &&
                          widget.onSend != null,
                      onSend: _submit,
                      child: TextField(
                        contentInsertionConfiguration:
                            widget.onContentInserted == null
                                ? null
                                : ContentInsertionConfiguration(
                                    onContentInserted:
                                        widget.onContentInserted!,
                                    allowedMimeTypes: const [
                                      'image/gif',
                                      'image/png',
                                      'image/jpeg',
                                      'image/webp',
                                    ],
                                  ),
                        controller: _controller,
                        focusNode: widget.focusNode,
                        enabled: widget.enabled,
                        minLines: 1,
                        maxLines: 5,
                        textAlign: TextAlign.start,
                        textAlignVertical: TextAlignVertical.center,
                        maxLength: 32000,
                        textCapitalization: TextCapitalization.sentences,
                        textInputAction: TextInputAction.newline,
                        onSubmitted: widget.onSubmitted,
                        onChanged: widget.onChanged,
                        style: Theme.of(context).textTheme.bodyMedium,
                        decoration: InputDecoration(
                          hintText: widget.hintText,
                          isDense: true,
                          constraints: const BoxConstraints(minHeight: 48),
                          counterText: '',
                          filled: false,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: LoomSpacing.sm,
                            vertical: 9,
                          ),
                        ),
                      ),
                    ),
              ),
            ),
            if (widget.actionOverride != null)
              widget.actionOverride!
            else
              LoomPressable(
                enabled: _canSend || _canVoice,
                child: IconButton.filled(
                  onPressed: _canVoice
                      ? widget.onVoice
                      : _canSend
                          ? _submit
                          : null,
                  style: IconButton.styleFrom(
                    backgroundColor: p.primary,
                    foregroundColor: p.onPrimary,
                    disabledBackgroundColor: p.surfaceMuted,
                    disabledForegroundColor: p.textMuted,
                    minimumSize: const Size.square(48),
                    fixedSize: const Size.square(48),
                    padding: EdgeInsets.zero,
                    alignment: Alignment.center,
                    shape: const CircleBorder(),
                  ),
                  icon: LoomComposerMorph(
                    child: widget.sending
                        ? SizedBox.square(
                            key: const ValueKey('queueing'),
                            dimension: 18,
                            child: reduceMotion
                                ? const Icon(
                                    LoomIcons.schedule_rounded,
                                    size: 18,
                                  )
                                : CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: p.onPrimary,
                                  ),
                          )
                        : Icon(
                            _voiceMode
                                ? LoomIcons.mic_none_rounded
                                : LoomIcons.arrow_upward_rounded,
                            key: ValueKey(_voiceMode ? 'voice' : 'send'),
                          ),
                  ),
                  tooltip:
                      _voiceMode ? widget.voiceTooltip : widget.sendTooltip,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
