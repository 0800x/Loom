import 'package:flutter/widgets.dart';

import '../../../app/loom_strings.dart';
import '../application/chat_folder_controller.dart';

String loomChatFolderDisplayName(
  BuildContext context,
  LoomChatFolderDefinition folder,
) => switch (folder.id) {
  loomAllChatsFolderId => tr(context, 'All', 'همه'),
  loomUnreadFolderId => tr(context, 'Unread', 'خوانده‌نشده'),
  loomPersonalFolderId => tr(context, 'Personal', 'شخصی'),
  loomGroupsFolderId => tr(context, 'Groups', 'گروه‌ها'),
  loomPinnedFolderId => tr(context, 'Pinned', 'سنجاق‌شده'),
  loomMutedFolderId => tr(context, 'Muted', 'بی‌صدا'),
  _ => folder.name,
};

String loomChatFolderLongDisplayName(
  BuildContext context,
  LoomChatFolderDefinition folder,
) => folder.id == loomAllChatsFolderId
    ? tr(context, 'All Chats', 'همه گفتگوها')
    : loomChatFolderDisplayName(context, folder);

String loomChatFolderDescription(
  BuildContext context,
  LoomChatFolderDefinition folder,
) {
  if (folder.id == loomAllChatsFolderId) {
    return tr(context, 'Every conversation', 'همه گفتگوها');
  }
  if (folder.id == loomUnreadFolderId) {
    return tr(
      context,
      'Chats with unread messages',
      'گفتگوهای دارای پیام خوانده‌نشده',
    );
  }
  if (folder.id == loomPersonalFolderId) {
    return tr(
      context,
      'Direct and Saved Messages',
      'گفتگوهای مستقیم و پیام‌های ذخیره‌شده',
    );
  }
  if (folder.id == loomGroupsFolderId) {
    return tr(context, 'Group conversations', 'گفتگوهای گروهی');
  }
  if (folder.id == loomPinnedFolderId) {
    return tr(context, 'Pinned conversations', 'گفتگوهای سنجاق‌شده');
  }
  if (folder.id == loomMutedFolderId) {
    return tr(context, 'Muted conversations', 'گفتگوهای بی‌صدا');
  }

  final parts = <String>[];
  if (folder.includeDirect) {
    parts.add(tr(context, 'Personal', 'شخصی'));
  }
  if (folder.includeGroups) {
    parts.add(tr(context, 'Groups', 'گروه‌ها'));
  }
  if (folder.includeSelf) {
    parts.add(tr(context, 'Saved', 'ذخیره‌شده'));
  }
  if (folder.unreadOnly) {
    parts.add(tr(context, 'Unread', 'خوانده‌نشده'));
  }
  if (folder.pinnedOnly) {
    parts.add(tr(context, 'Pinned', 'سنجاق‌شده'));
  }
  if (folder.mutedOnly) {
    parts.add(tr(context, 'Muted', 'بی‌صدا'));
  }
  return parts.isEmpty
      ? tr(context, 'All conversation types', 'همه انواع گفتگو')
      : parts.join(' · ');
}
