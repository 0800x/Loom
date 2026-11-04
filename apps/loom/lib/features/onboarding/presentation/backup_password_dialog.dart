import 'package:flutter/material.dart';

class LoomBackupExportPasswordChoice {
  const LoomBackupExportPasswordChoice({
    required this.cancelled,
    required this.isProtected,
    this.password,
  });

  final bool cancelled;
  final bool isProtected;
  final String? password;
}

/// Lets users choose an encrypted recovery export or an explicitly unprotected
/// file. Encryption is the default and requires a confirmed 12-character
/// password; the password is never persisted.
Future<LoomBackupExportPasswordChoice?> showLoomBackupExportPasswordDialog(
  BuildContext context,
) async {
  final password = TextEditingController();
  final confirmation = TextEditingController();
  var protect = true;
  String? error;

  try {
    return await showDialog<LoomBackupExportPasswordChoice>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Protect recovery file'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                value: protect,
                title: const Text('Encrypt this recovery file'),
                onChanged: (value) => setState(() {
                  protect = value;
                  error = null;
                }),
              ),
              if (protect) ...[
                TextField(
                  controller: password,
                  obscureText: true,
                  autofillHints: const [AutofillHints.newPassword],
                  decoration: const InputDecoration(
                    labelText: 'Export password (12+ characters)',
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: confirmation,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Confirm password',
                  ),
                ),
              ],
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(
                dialogContext,
                const LoomBackupExportPasswordChoice(
                  cancelled: true,
                  isProtected: false,
                ),
              ),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                if (protect) {
                  if (password.text.length < 12) {
                    setState(() => error = 'Use at least 12 characters.');
                    return;
                  }
                  if (password.text != confirmation.text) {
                    setState(() => error = 'Passwords do not match.');
                    return;
                  }
                }
                Navigator.pop(
                  dialogContext,
                  LoomBackupExportPasswordChoice(
                    cancelled: false,
                    isProtected: protect,
                    password: protect ? password.text : null,
                  ),
                );
              },
              child: const Text('Continue'),
            ),
          ],
        ),
      ),
    );
  } finally {
    password.dispose();
    confirmation.dispose();
  }
}


/// Prompts for the password protecting an imported recovery file.
///
/// Returning null means the user cancelled. The caller owns the returned
/// string and must not persist it.
Future<String?> showLoomBackupImportPasswordDialog(
  BuildContext context, {
  String? errorText,
}) async {
  final password = TextEditingController();
  var visible = false;
  try {
    return await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Unlock recovery file'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Enter the password used when this recovery file was exported.',
              ),
              const SizedBox(height: 12),
              TextField(
                controller: password,
                autofocus: true,
                obscureText: !visible,
                autocorrect: false,
                enableSuggestions: false,
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) {
                  if (password.text.isNotEmpty) {
                    Navigator.pop(dialogContext, password.text);
                  }
                },
                decoration: InputDecoration(
                  labelText: 'Recovery-file password',
                  errorText: errorText,
                  suffixIcon: IconButton(
                    tooltip: visible ? 'Hide password' : 'Show password',
                    onPressed: () => setState(() => visible = !visible),
                    icon: Icon(
                      visible ? Icons.visibility_off : Icons.visibility,
                    ),
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: password.text.isEmpty
                  ? null
                  : () => Navigator.pop(dialogContext, password.text),
              child: const Text('Unlock'),
            ),
          ],
        ),
      ),
    );
  } finally {
    password.dispose();
  }
}
