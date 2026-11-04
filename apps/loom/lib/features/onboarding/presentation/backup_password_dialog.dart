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
