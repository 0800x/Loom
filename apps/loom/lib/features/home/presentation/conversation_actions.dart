part of 'messenger_shell.dart';

class _ConversationDrafts {
  final _text = <String, TextEditingValue>{};
  final galleries = <String, _GalleryDraft>{};
  final scrollOffsets = <String, double>{};
  void dispose() {
    for (final gallery in galleries.values) {
      gallery.dispose();
    }
  }

  final replies = <String, LoomVisibleMessage>{};
  final editing = <String, LoomVisibleMessage>{};
  TextEditingValue? operator [](String? id) => _text[id];
  void operator []=(String id, TextEditingValue value) => _text[id] = value;
  TextEditingValue? remove(String id) => _text.remove(id);
}

List<(String, IconData, String)> _conversationManagementItems(
  BuildContext context,
  models.LoomConversation conversation,
  bool archived,
) => [
  (
    'archive',
    LoomIcons.archive_outlined,
    archived
        ? tr(context, 'Unarchive', 'خروج از بایگانی')
        : tr(context, 'Archive', 'بایگانی'),
  ),
  (
    'mute',
    conversation.isMuted
        ? LoomIcons.notifications_none_rounded
        : LoomIcons.notifications_off_outlined,
    conversation.isMuted
        ? tr(context, 'Unmute', 'فعال کردن اعلان‌ها')
        : tr(context, 'Mute', 'بی‌صدا'),
  ),
  (
    'pin',
    LoomIcons.push_pin_outlined,
    conversation.isPinned
        ? tr(context, 'Unpin', 'برداشتن سنجاق')
        : tr(context, 'Pin', 'سنجاق'),
  ),
  (
    'read',
    LoomIcons.done_all,
    tr(context, 'Mark as read', 'علامت‌گذاری خوانده‌شده'),
  ),
  (
    'unread',
    LoomIcons.chat_bubble_outline_rounded,
    tr(context, 'Mark as unread', 'علامت‌گذاری خوانده‌نشده'),
  ),
  if (conversation.kind != models.LoomConversationKind.group)
    (
      'clear',
      LoomIcons.cleaning_services_outlined,
      tr(context, 'Clear local history', 'پاک کردن تاریخچهٔ محلی'),
    ),
  if (conversation.kind != models.LoomConversationKind.group)
    (
      'delete',
      LoomIcons.delete_outline_rounded,
      tr(context, 'Delete chat from this device', 'حذف گفتگو از این دستگاه'),
    ),
];

Future<String?> _conversationContextMenu(
  BuildContext context,
  models.LoomConversation conversation,
  LoomMessagingSessionController messaging, {
  Offset? position,
}) {
  final overlay =
      Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
  final origin = LoomOrigin.of(context) ?? const Rect.fromLTWH(16, 16, 1, 1);
  final point = overlay.globalToLocal(position ?? origin.topRight);
  return showLoomAnchoredMenu<String>(
    context: context,
    position: RelativeRect.fromRect(
      point & const Size(1, 1),
      Offset.zero & overlay.size,
    ),
    items: [
      for (final item in [
        (
          'details',
          LoomIcons.person_outline,
          conversation.kind == models.LoomConversationKind.group
              ? tr(context, 'Members and invitations', 'اعضا و دعوت‌ها')
              : tr(context, 'View profile', 'مشاهدهٔ پروفایل'),
        ),
        ..._conversationManagementItems(
          context,
          conversation,
          messaging.isArchived(conversation.id),
        ),
      ])
        PopupMenuItem(
          value: item.$1,
          child: Row(
            children: [
              Icon(item.$2, size: 20),
              const SizedBox(width: 12),
              Flexible(child: Text(item.$3)),
            ],
          ),
        ),
    ],
  );
}

Future<bool> _manageConversation(
  BuildContext context,
  String action,
  models.LoomConversation conversation,
  LoomMessagingSessionController messaging,
) async {
  final id = conversation.id;
  try {
    switch (action) {
      case 'details':
        if (conversation.kind == models.LoomConversationKind.group) {
          await Navigator.push<void>(
            context,
            MaterialPageRoute<void>(
              builder: (_) =>
                  LoomGroupsScreen(initialGroupId: id, managementOnly: true),
            ),
          );
        }
      case 'archive':
        await messaging.setConversationArchived(id, !messaging.isArchived(id));
      case 'pin':
        await messaging.setConversationPinned(id, !conversation.isPinned);
      case 'mute':
        if (conversation.isMuted) {
          await messaging.setConversationMuted(id, false);
        } else {
          final duration = await showDialog<Duration>(
            context: context,
            builder: (dialog) => SimpleDialog(
              title: Text(
                tr(context, 'Mute notifications', 'بی‌صدا کردن اعلان‌ها'),
              ),
              children: [
                for (final option in [
                  (const Duration(hours: 1), tr(context, '1 hour', '۱ ساعت')),
                  (const Duration(hours: 8), tr(context, '8 hours', '۸ ساعت')),
                  (const Duration(days: 2), tr(context, '2 days', '۲ روز')),
                  (
                    Duration.zero,
                    tr(context, 'Until I unmute', 'تا فعال کردن دوباره'),
                  ),
                ])
                  SimpleDialogOption(
                    onPressed: () => Navigator.pop(dialog, option.$1),
                    child: Text(option.$2),
                  ),
              ],
            ),
          );
          if (duration == null || !context.mounted) return true;
          await messaging.setConversationMuted(
            id,
            true,
            until: duration == Duration.zero
                ? null
                : DateTime.now().toUtc().add(duration),
          );
        }
      case 'read':
        await messaging.markConversationRead(id);
      case 'unread':
        await messaging.markConversationUnread(id);
      case 'delete':
        if (await _confirmLocalDeletion(context, chat: true)) {
          await messaging.deleteLocalConversation(id);
        }
      case 'clear':
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialog) => AlertDialog(
            title: Text(
              tr(context, 'Clear local history?', 'پاک کردن تاریخچهٔ محلی؟'),
            ),
            content: Text(
              tr(
                context,
                'Removes messages and pending sends from this device. The chat and contact stay. Copies on other devices remain.',
                'پیام‌ها و ارسال‌های در صف از این دستگاه حذف می‌شوند. گفتگو و مخاطب باقی می‌مانند؛ نسخهٔ دستگاه‌های دیگر حفظ می‌شود.',
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialog, false),
                child: Text(tr(context, 'Cancel', 'انصراف')),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialog, true),
                child: Text(tr(context, 'Clear', 'پاک کردن')),
              ),
            ],
          ),
        );
        if (confirmed == true) {
          await messaging.clearLocalConversationHistory(id);
        }
      default:
        return false;
    }
  } catch (_) {
    if (context.mounted) {
      _showComingSoon(
        context,
        tr(
          context,
          'The change could not be saved. Try again.',
          'تغییر ذخیره نشد؛ دوباره تلاش کنید.',
        ),
      );
    }
  }
  return true;
}

Future<models.LoomCallKind?> _chooseConversationCall(
  BuildContext context,
  String name, {
  required bool enabled,
}) => showLoomActionSheet<models.LoomCallKind>(
  context: context,
  title: tr(context, 'Call $name', 'تماس با $name'),
  subtitle: tr(
    context,
    'Choose how you want to connect.',
    'صوتی صحبت کنیم یا تصویری؟',
  ),
  builder: (context) => LoomActionGrid(
    children: [
      LoomActionTile(
        icon: LoomIcons.call_outlined,
        label: tr(context, 'Audio call', 'تماس صوتی'),
        subtitle: tr(context, 'Just your voice', 'فقط صدا'),
        color: context.loom.connectivity,
        onTap: enabled
            ? () => Navigator.pop(context, models.LoomCallKind.audio)
            : null,
      ),
      LoomActionTile(
        icon: LoomIcons.videocam_outlined,
        label: tr(context, 'Video call', 'تماس ویدیویی'),
        subtitle: tr(context, 'Face to face', 'رو در رو'),
        onTap: enabled
            ? () => Navigator.pop(context, models.LoomCallKind.video)
            : null,
      ),
    ],
  ),
);

const _quickReactions = <String>['👍', '👎', '❤️', '😂', '😮', '😢', '🙏'];

Future<String?> _chooseMessageAction(
  BuildContext context,
  LoomVisibleMessage message, {
  Rect? origin,
  required bool canDeleteForEveryone,
  required bool canEdit,
}) => showLoomActionSheet<String>(
  context: context,
  title: tr(context, 'Message', 'پیام'),
  origin: origin,
  builder: (context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: context.loom.surfaceMuted,
          borderRadius: BorderRadius.circular(12),
          border: BorderDirectional(
            start: BorderSide(color: context.loom.primary, width: 3),
          ),
        ),
        child: Text(message.text, maxLines: 3, overflow: TextOverflow.ellipsis),
      ),
      const SizedBox(height: 8),
      if (message.readable && !canEdit)
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            for (final emoji in _quickReactions)
              InkWell(
                borderRadius: BorderRadius.circular(24),
                onTap: () => Navigator.pop(context, 'react:$emoji'),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 6,
                  ),
                  child: Text(emoji, style: const TextStyle(fontSize: 24)),
                ),
              ),
          ],
        ),
      const SizedBox(height: 4),
      if (message.readable) ...[
        LoomPressable(
          child: ListTile(
            leading: const Icon(LoomIcons.reply_rounded),
            title: Text(tr(context, 'Reply', 'پاسخ')),
            onTap: () => Navigator.pop(context, 'reply'),
          ),
        ),
        LoomPressable(
          child: ListTile(
            leading: const Icon(LoomIcons.ios_share_rounded),
            title: Text(tr(context, 'Forward', 'فوروارد')),
            onTap: () => Navigator.pop(context, 'forward'),
          ),
        ),
      ],
      if (canEdit)
        LoomPressable(
          child: ListTile(
            leading: const Icon(LoomIcons.edit_outlined),
            title: Text(tr(context, 'Edit', 'ویرایش')),
            onTap: () => Navigator.pop(context, 'edit'),
          ),
        ),
      if (canDeleteForEveryone)
        LoomPressable(
          child: ListTile(
            leading: const Icon(LoomIcons.delete_outline_rounded),
            title: Text(
              tr(context, 'Delete for everyone', 'حذف برای همه'),
            ),
            onTap: () => Navigator.pop(context, 'deleteEveryone'),
          ),
        ),
      if (message.record.protocolVersion != models.loomGroupProtocol)
        LoomPressable(
          child: ListTile(
            leading: const Icon(LoomIcons.delete_outline_rounded),
            title: Text(
              tr(context, 'Delete from this device', 'حذف از این دستگاه'),
            ),
            onTap: () => Navigator.pop(context, 'delete'),
          ),
        ),
      if (message.readable && message.content.text.isNotEmpty) ...[
        LoomPressable(
          child: ListTile(
            leading: const Icon(LoomIcons.copy_outlined),
            title: Text(tr(context, 'Copy', 'کپی')),
            onTap: () => Navigator.pop(context, 'copy'),
          ),
        ),
        LoomPressable(
          child: ListTile(
            leading: const Icon(LoomIcons.text_fields),
            title: Text(tr(context, 'Select text', 'انتخاب متن')),
            onTap: () => Navigator.pop(context, 'select'),
          ),
        ),
      ],
    ],
  ),
);

Future<void> _showDeliveryGuide(BuildContext context) =>
    showLoomActionSheet<void>(
      context: context,
      title: tr(context, 'Message status', 'وضعیت پیام'),
      builder: (context) => Column(
        children: [
          ListTile(
            leading: Icon(LoomIcons.check, color: context.loom.textMuted),
            title: Text(tr(context, 'Sent', 'ارسال‌شده')),
            subtitle: Text(
              tr(
                context,
                'Accepted by your Home Node.',
                'گرهٔ اصلی شما پیام را پذیرفته است.',
              ),
            ),
          ),
          ListTile(
            leading: Icon(LoomIcons.done_all, color: context.loom.textMuted),
            title: Text(tr(context, 'Delivered', 'دریافت‌شده')),
            subtitle: Text(
              tr(
                context,
                'Received by a recipient device.',
                'دستگاه گیرنده پیام را دریافت کرده است.',
              ),
            ),
          ),
          ListTile(
            leading: Icon(LoomIcons.done_all, color: context.loom.info),
            title: Text(tr(context, 'Read', 'خوانده‌شده')),
          ),
          ListTile(
            leading: Icon(
              LoomIcons.wifi_tethering,
              color: context.loom.primary,
            ),
            title: Text(tr(context, 'Nearby route', 'مسیر نزدیک')),
            subtitle: Text(
              tr(
                context,
                'Shows the route, not whether the person has read the message.',
                'مسیر انتقال را نشان می‌دهد؛ به معنی خواندن پیام نیست.',
              ),
            ),
          ),
        ],
      ),
    );

Future<bool> _confirmLocalDeletion(
  BuildContext context, {
  bool chat = false,
}) async =>
    await showLoomActionSheet<bool>(
      context: context,
      title: tr(
        context,
        chat ? 'Delete chat?' : 'Delete message?',
        chat ? 'حذف گفتگو؟' : 'حذف پیام؟',
      ),
      subtitle: tr(
        context,
        'Removed from this device only. Copies on the server and other devices remain. Pending local sends are cancelled; a send already in progress may complete.',
        'فقط از این دستگاه حذف می‌شود؛ نسخهٔ سرور و دستگاه‌های دیگر باقی می‌ماند. ارسال‌های در صف لغو می‌شوند؛ ارسال در حال انجام ممکن است کامل شود.',
      ),
      builder: (context) => Row(
        children: [
          Expanded(
            child: TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(tr(context, 'Cancel', 'انصراف')),
            ),
          ),
          Expanded(
            child: FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(tr(context, 'Delete', 'حذف')),
            ),
          ),
        ],
      ),
    ) ??
    false;

/// Conversation picker for forwarding. Returns the target conversation id or
/// null when cancelled. Includes Saved Messages, direct chats and groups.
Future<String?> _forwardMessagePicker(
  BuildContext context,
  LoomMessagingSessionController messaging,
) {
  final queryFocus = FocusNode();
  var filter = '';
  return showLoomActionSheet<String>(
    context: context,
    title: tr(context, 'Forward to', 'فوروارد به'),
    builder: (sheetContext) => StatefulBuilder(
      builder: (sheetContext, setSheetState) {
        final query = filter.trim().toLowerCase();
        final targets = messaging.conversations
            .where(
              (conversation) =>
                  !messaging.isPeerBlocked(conversation.peerAddress) &&
                  (query.isEmpty ||
                      (conversation.title ?? '').toLowerCase().contains(query)),
            )
            .toList(growable: false);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              autofocus: true,
              focusNode: queryFocus,
              onChanged: (value) => setSheetState(() => filter = value),
              decoration: InputDecoration(
                prefixIcon: const Icon(LoomIcons.search_rounded),
                hintText: tr(context, 'Search', 'جستجو'),
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.heightOf(sheetContext) * 0.42,
                ),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: targets.length,
                  itemBuilder: (itemContext, index) {
                    final conversation = targets[index];
                    return ListTile(
                      leading: Icon(
                        conversation.kind == models.LoomConversationKind.group
                            ? LoomIcons.groups_outlined
                            : conversation.kind ==
                                  models.LoomConversationKind.self
                            ? LoomIcons.bookmark_border_rounded
                            : LoomIcons.person_outline,
                      ),
                      title: Text(
                        conversation.title ??
                            tr(context, 'Conversation', 'گفتگو'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () => Navigator.pop(sheetContext, conversation.id),
                    );
                  },
                ),
              ),
            ),
          ],
        );
      },
    ),
  ).whenComplete(queryFocus.dispose);
}

/// Compact reaction chips under a bubble. Each chip shows the emoji and the
/// number of senders; the caller's own reaction is highlighted.
class _MessageReactionChips extends StatelessWidget {
  const _MessageReactionChips({
    required this.reactions,
    required this.ownAddress,
    this.onTap,
  });

  final List<LoomReactionEntry> reactions;
  final String? ownAddress;
  final ValueChanged<String>? onTap;

  @override
  Widget build(BuildContext context) {
    final own = ownAddress?.toLowerCase();
    final grouped = <String, int>{};
    var ownEmoji = '';
    for (final reaction in reactions) {
      grouped[reaction.emoji] = (grouped[reaction.emoji] ?? 0) + 1;
      if (own != null && reaction.sender.toLowerCase() == own) {
        ownEmoji = reaction.emoji;
      }
    }
    final entries = grouped.entries.toList(growable: false);
    return Padding(
      padding: const EdgeInsets.only(top: 3, bottom: 2),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        children: [
          for (final entry in entries)
            InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: onTap == null ? null : () => onTap!(entry.key),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 3,
                ),
                decoration: BoxDecoration(
                  color: entry.key == ownEmoji
                      ? context.loom.primary.withValues(alpha: .18)
                      : context.loom.surfaceElevated,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: entry.key == ownEmoji
                        ? context.loom.primary
                        : context.loom.surfaceMuted,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(entry.key, style: const TextStyle(fontSize: 14)),
                    if (entry.value > 1) ...[
                      const SizedBox(width: 3),
                      Text(
                        '${entry.value}',
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    ],
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Typing row shown above the composer while peers are actively typing.
class _TypingIndicator extends StatelessWidget {
  const _TypingIndicator({required this.peers});

  final Map<String, DateTime> peers;

  @override
  Widget build(BuildContext context) {
    if (peers.isEmpty) {
      return const SizedBox.shrink();
    }
    final names = peers.keys.toList(growable: false);
    final label = names.length == 1
        ? tr(context, '${names.first} is typing…', '${names.first} در حال نوشتن…')
        : names.length == 2
        ? tr(
            context,
            'Two people are typing…',
            'دو نفر در حال نوشتن…',
          )
        : tr(context, 'Several people are typing…', 'چند نفر در حال نوشتن…');
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 2),
      child: Row(
        children: [
          SizedBox.square(
            dimension: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: context.loom.primary,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: context.loom.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}
