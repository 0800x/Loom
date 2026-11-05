import 'package:loom_design/loom_design.dart';
import 'package:flutter/material.dart';

/// Flat Telegram-style confirmation dialog built on the shared dialog theme.
///
/// Returns true when the user confirms. [destructive] renders the confirm
/// action in the critical color (delete / leave / block confirmations).
Future<bool> showLoomConfirmDialog({
  required BuildContext context,
  required String title,
  String? message,
  String? confirmLabel,
  String? cancelLabel,
  bool destructive = false,
}) async {
  final p = context.loom;
  final local = MaterialLocalizations.of(context);
  final result = await showDialog<bool>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: Text(title),
      content: message == null ? null : Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialog, false),
          child: Text(cancelLabel ?? local.cancelButtonLabel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialog, true),
          style: destructive
              ? FilledButton.styleFrom(
                  backgroundColor: p.critical,
                  foregroundColor: Colors.white,
                )
              : null,
          child: Text(confirmLabel ?? local.okButtonLabel),
        ),
      ],
    ),
  );
  return result == true;
}

/// A single-choice list dialog in the flat Telegram style: rows with a
/// leading icon, title and optional subtitle, and optional trailing check
/// mark for the selected value. Returns the selected value or null.
Future<T?> showLoomChoiceDialog<T>({
  required BuildContext context,
  required String title,
  required List<({T value, String title, String? subtitle, IconData? icon})>
  options,
  T? selected,
  String? cancelLabel,
}) async {
  final p = context.loom;
  final result = await showDialog<T>(
    context: context,
    builder: (dialog) => SimpleDialog(
      title: Text(title),
      children: [
        for (var i = 0; i < options.length; i++)
          InkWell(
            onTap: () => Navigator.pop(dialog, options[i].value),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsetsDirectional.only(
                    start: 16,
                    end: 16,
                    top: 10,
                    bottom: 10,
                  ),
                  child: Row(
                    children: [
                      if (options[i].icon != null) ...[
                        SizedBox.square(
                          dimension: 34,
                          child: Icon(
                            options[i].icon,
                            size: 20,
                            color: p.textSecondary,
                          ),
                        ),
                        const SizedBox(width: 12),
                      ],
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              options[i].title,
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(fontWeight: FontWeight.w600),
                            ),
                            if (options[i].subtitle != null) ...[
                              const SizedBox(height: 2),
                              Text(
                                options[i].subtitle!,
                                style: Theme.of(context).textTheme.labelSmall
                                    ?.copyWith(color: p.textSecondary),
                              ),
                            ],
                          ],
                        ),
                      ),
                      if (selected == options[i].value)
                        Icon(LoomIcons.check_rounded, color: p.primary),
                    ],
                  ),
                ),
                if (i < options.length - 1)
                  Padding(
                    padding: const EdgeInsetsDirectional.only(start: 16),
                    child: Divider(height: 1, color: p.border),
                  ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Align(
            alignment: AlignmentDirectional.centerEnd,
            child: TextButton(
              onPressed: () => Navigator.pop(dialog),
              child: Text(
                cancelLabel ??
                    MaterialLocalizations.of(
                      dialog,
                    ).cancelButtonLabel,
              ),
            ),
          ),
        ),
      ],
    ),
  );
  return result;
}
