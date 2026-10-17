import 'package:loom_design/loom_design.dart';
import 'package:loom_storage/loom_storage.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../../app/loom_strings.dart';
import '../application/messaging_session_controller.dart';

/// Local-only cleanup UI for pre-alpha testing.
///
/// This intentionally does not claim server-side or "delete for everyone"
/// semantics. It removes the selected encrypted message/history from this
/// device and cancels matching local pending sends.
class LoomLocalMessageCleanupScreen extends StatefulWidget {
  const LoomLocalMessageCleanupScreen({super.key});

  @override
  State<LoomLocalMessageCleanupScreen> createState() =>
      _LoomLocalMessageCleanupScreenState();
}

class _LoomLocalMessageCleanupScreenState
    extends State<LoomLocalMessageCleanupScreen> {
  bool _busy = false;
  String? _error;

  Future<String> _databasePath() async {
    final support = await getApplicationSupportDirectory();
    return '${support.path}/loom-messages-v1.sqlite3';
  }

  Future<void> _deleteMessage(
    LoomMessagingSessionController messaging,
    LoomVisibleMessage message,
  ) async {
    final confirmed = await _confirm(
      title: tr(context, 'Delete local message?', 'پیام محلی پاک شود؟'),
      body: tr(
        context,
        'This removes the message only from this device and cancels its local pending send, if any. It does not delete it from the server or another device.',
        'این کار پیام را فقط از همین گوشی پاک می‌کند و ارسال pending محلی آن را هم لغو می‌کند. از سرور یا گوشی دیگر پاک نمی‌شود.',
      ),
    );
    if (!confirmed || !mounted) return;
    await _run(() async {
      LoomLocalMessagingCleanup.deleteMessageByClientId(
        databasePath: await _databasePath(),
        clientId: message.record.clientId,
      );
      await messaging.synchronize();
    });
  }

  Future<void> _clearConversation(
    LoomMessagingSessionController messaging,
    String conversationId,
  ) async {
    final confirmed = await _confirm(
      title: tr(context, 'Clear local chat?', 'تاریخچه محلی پاک شود؟'),
      body: tr(
        context,
        'All locally stored messages and pending sends in this chat will be removed from this device. The conversation can still exist on the Home Node and on other devices.',
        'همه پیام‌های ذخیره‌شده و ارسال‌های pending این گفتگو از همین گوشی پاک می‌شوند. خود گفتگو ممکن است همچنان روی Home Node یا دستگاه‌های دیگر وجود داشته باشد.',
      ),
    );
    if (!confirmed || !mounted) return;
    await _run(() async {
      LoomLocalMessagingCleanup.clearConversation(
        databasePath: await _databasePath(),
        conversationId: conversationId,
      );
      await messaging.synchronize();
    });
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = _safeError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirm({required String title, required String body}) async {
    return await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(title),
            content: Text(body),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: Text(tr(context, 'Delete', 'پاک کردن')),
              ),
            ],
          ),
        ) ??
        false;
  }

  static String _safeError(Object error) {
    final text = error.toString().replaceAll(RegExp(r'[\r\n]+'), ' ');
    return text.length <= 240 ? text : text.substring(0, 240);
  }

  @override
  Widget build(BuildContext context) {
    final messaging = LoomMessagingSessionScope.maybeOf(context);
    final conversations = messaging?.conversations ?? const [];
    return Scaffold(
      appBar: LoomGlassAppBar(
        title: Text(tr(context, 'Local message cleanup', 'پاک‌سازی محلی پیام‌ها')),
      ),
      body: messaging == null
          ? Center(
              child: Text(
                tr(
                  context,
                  'Messaging session is unavailable.',
                  'نشست پیام‌رسان در دسترس نیست.',
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
              children: [
                Text(
                  tr(
                    context,
                    'Testing utility: deletions here are local-only. They do not mean delete-for-everyone.',
                    'ابزار تست: حذف‌های این صفحه فقط محلی‌اند و به معنی حذف برای همه نیستند.',
                  ),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (_busy) ...[
                  const SizedBox(height: 12),
                  const LinearProgressIndicator(),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ],
                const SizedBox(height: 12),
                if (conversations.isEmpty)
                  Text(tr(context, 'No local chats.', 'گفتگوی محلی وجود ندارد.'))
                else
                  for (final conversation in conversations)
                    Builder(
                      builder: (context) {
                        final messages =
                            messaging.visibleMessagesFor(conversation.id);
                        final title = conversation.title?.trim().isNotEmpty == true
                            ? conversation.title!.trim()
                            : conversation.peerAddress?.trim().isNotEmpty == true
                                ? conversation.peerAddress!.trim()
                                : conversation.id;
                        return Card(
                          child: ExpansionTile(
                            title: Text(title),
                            subtitle: Text(
                              tr(
                                context,
                                '${messages.length} local message(s)',
                                '${messages.length} پیام محلی',
                              ),
                            ),
                            children: [
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 6,
                                ),
                                child: Align(
                                  alignment: AlignmentDirectional.centerEnd,
                                  child: TextButton(
                                    onPressed: _busy
                                        ? null
                                        : () => _clearConversation(
                                              messaging,
                                              conversation.id,
                                            ),
                                    child: Text(
                                      tr(
                                        context,
                                        'Clear local chat',
                                        'پاک کردن تاریخچه محلی',
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              if (messages.isEmpty)
                                Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: Text(
                                    tr(
                                      context,
                                      'No local messages.',
                                      'پیام محلی وجود ندارد.',
                                    ),
                                  ),
                                )
                              else
                                for (final message in messages)
                                  ListTile(
                                    title: Text(
                                      message.readable
                                          ? message.text
                                          : tr(
                                              context,
                                              'Encrypted message',
                                              'پیام رمزگذاری‌شده',
                                            ),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    subtitle: Text(
                                      '${message.record.deliveryState.name} · '
                                      '${message.record.createdAt.toLocal()}',
                                    ),
                                    trailing: TextButton(
                                      onPressed: _busy
                                          ? null
                                          : () => _deleteMessage(
                                                messaging,
                                                message,
                                              ),
                                      child: Text(
                                        tr(context, 'Delete', 'پاک کردن'),
                                      ),
                                    ),
                                  ),
                            ],
                          ),
                        );
                      },
                    ),
              ],
            ),
    );
  }
}

