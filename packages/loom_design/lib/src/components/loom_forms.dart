import 'package:flutter/material.dart';

import '../loom_glass.dart';
import '../loom_theme.dart';
import '../loom_tokens.dart';
import 'loom_identity.dart';

/// Selection is one accessible, keyboard-focusable action for the whole row.
class LoomSelectionRow extends StatelessWidget {
  const LoomSelectionRow({
    required this.label,
    required this.detail,
    required this.selected,
    required this.onTap,
    this.enabled = true,
    this.unavailableLabel,
    super.key,
  });
  final String label, detail;
  final String? unavailableLabel;
  final bool selected, enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: LoomSpacing.xxs),
        child: Material(
          color: selected
              ? context.loom.primary.withAlphaFraction(LoomOpacity.selected)
              : context.loom.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(LoomRadii.control),
            side: BorderSide(
              color: selected ? context.loom.primary : context.loom.border,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: CheckboxListTile(
            value: selected,
            onChanged: enabled ? (_) => onTap() : null,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: LoomSpacing.sm),
            secondary: ExcludeSemantics(
              child: LoomAvatar(label: label, size: LoomSizing.compactAvatar),
            ),
            title: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  detail,
                  textDirection: TextDirection.ltr,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (!enabled && unavailableLabel != null)
                  Text(
                    unavailableLabel!,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
            ),
          ),
        ),
      );
}

/// Shared inline feedback stays with the action that failed. Wrap permits long
/// translations and large text without squeezing retry into an icon.
class LoomFeedbackSurface extends StatelessWidget {
  const LoomFeedbackSurface({
    required this.message,
    this.actionLabel,
    this.onAction,
    this.error = true,
    super.key,
  });
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final bool error;

  @override
  Widget build(BuildContext context) => Semantics(
        liveRegion: true,
        child: LoomGlassSurface(
          padding: const EdgeInsets.all(LoomSpacing.md),
          radius: LoomRadii.control,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                message,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: error
                          ? context.loom.critical
                          : context.loom.textPrimary,
                    ),
              ),
              if (actionLabel != null) ...[
                const SizedBox(height: LoomSpacing.xs),
                TextButton(onPressed: onAction, child: Text(actionLabel!)),
              ],
            ],
          ),
        ),
      );
}

/// Field, validation, progress and recovery belong to the dialog's lifetime.
/// This avoids dismissing a draft before a remote action has actually succeeded.
class LoomAsyncTextDialog extends StatefulWidget {
  const LoomAsyncTextDialog({
    required this.title,
    required this.label,
    required this.actionLabel,
    required this.cancelLabel,
    required this.failureLabel,
    required this.onSubmit,
    required this.validator,
    this.initialValue = '',
    this.hint,
    this.maxLength,
    this.textDirection,
    super.key,
  });
  final String title,
      label,
      actionLabel,
      cancelLabel,
      failureLabel,
      initialValue;
  final String? hint;
  final int? maxLength;
  final TextDirection? textDirection;
  final Future<bool> Function(String) onSubmit;
  final FormFieldValidator<String> validator;
  @override
  State<LoomAsyncTextDialog> createState() => _LoomAsyncTextDialogState();
}

class _LoomAsyncTextDialogState extends State<LoomAsyncTextDialog> {
  final _form = GlobalKey<FormState>();
  late final _input = TextEditingController(text: widget.initialValue);
  bool _busy = false, _complete = false, _failed = false;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy || _complete || !_form.currentState!.validate()) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _busy = true;
      _failed = false;
    });
    var success = false;
    try {
      success = await widget.onSubmit(_input.text.trim());
    } catch (_) {
      success = false;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _complete = success;
      _failed = !success;
    });
    if (success) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.pop(context, true);
      });
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: !_busy,
        child: AlertDialog(
          scrollable: true,
          title: Text(widget.title),
          content: SizedBox(
            width: LoomSizing.dialogMax,
            child: Form(
              key: _form,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    controller: _input,
                    autofocus: true,
                    enabled: !_busy && !_complete,
                    textDirection: widget.textDirection,
                    maxLength: widget.maxLength,
                    textInputAction: TextInputAction.done,
                    decoration: InputDecoration(
                      labelText: widget.label,
                      hintText: widget.hint,
                    ),
                    validator: widget.validator,
                    onFieldSubmitted: (_) => _submit(),
                  ),
                  if (_busy) const LinearProgressIndicator(),
                  if (_failed) ...[
                    const SizedBox(height: LoomSpacing.sm),
                    LoomFeedbackSurface(message: widget.failureLabel),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: _busy || _complete
                  ? null
                  : () => Navigator.pop(context, false),
              child: Text(widget.cancelLabel),
            ),
            FilledButton(
              onPressed: _busy || _complete ? null : _submit,
              child: Text(widget.actionLabel),
            ),
          ],
        ),
      );
}
