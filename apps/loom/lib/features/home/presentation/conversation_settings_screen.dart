part of 'messenger_shell.dart';

/// Full settings surface for a conversation, opened from the slimmed-down
/// chat menu. Groups everything that used to clutter the three-dot menu:
/// management (archive/mute/pin/read), per-chat appearance, group info,
/// local history tools and the message status guide.
class LoomConversationSettingsScreen extends StatefulWidget {
  const LoomConversationSettingsScreen({
    required this.conversation,
    required this.messaging,
    super.key,
  });

  final models.LoomConversation conversation;
  final LoomMessagingSessionController messaging;

  @override
  State<LoomConversationSettingsScreen> createState() =>
      _LoomConversationSettingsScreenState();
}

class _LoomConversationSettingsScreenState
    extends State<LoomConversationSettingsScreen> {
  @override
  Widget build(BuildContext context) {
    final conversation = widget.conversation;
    final messaging = widget.messaging;
    final isGroup = conversation.kind == models.LoomConversationKind.group;
    final archived = messaging.isArchived(conversation.id);
    final title = _conversationTitle(context, conversation);
    return Scaffold(
      appBar: LoomGlassAppBar(
        title: Text(tr(context, 'Chat settings', 'تنظیمات گفتگو')),
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ListenableBuilder(
          listenable: widget.messaging,
          builder: (context, _) => ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              _headerCard(context, title, isGroup),
              if (isGroup) ...[
                _sectionTitle(
                  context,
                  tr(context, 'Group', 'گروه'),
                ),
                LoomSettingsGroup(
                  children: [
                    LoomSettingsRow(
                      icon: LoomIcons.groups_outlined,
                      title: tr(
                        context,
                        'Group info & members',
                        'اطلاعات و اعضای گروه',
                      ),
                      subtitle: tr(
                        context,
                        'Rename, members, invitations, leave',
                        'تغییر نام، اعضا، دعوت‌ها، خروج',
                      ),
                      onTap: () => unawaited(
                        Navigator.push<void>(
                          context,
                          MaterialPageRoute<void>(
                            builder: (_) => LoomGroupsScreen(
                              initialGroupId: conversation.id,
                              managementOnly: true,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              _sectionTitle(
                context,
                tr(context, 'Notifications and list', 'اعلان‌ها و فهرست'),
              ),
              LoomSettingsGroup(
                children: [
                  LoomSettingsRow(
                    icon: conversation.isMuted
                        ? LoomIcons.notifications_off_outlined
                        : LoomIcons.notifications_none_rounded,
                    title: conversation.isMuted
                        ? tr(context, 'Unmute', 'فعال کردن اعلان‌ها')
                        : tr(context, 'Mute', 'بی‌صدا'),
                    trailing: Switch(
                      value: !conversation.isMuted,
                      onChanged: (_) => unawaited(
                        _run(
                          conversation.isMuted ? 'unmute' : 'mute',
                        ),
                      ),
                    ),
                    onTap: () => unawaited(
                      _run(conversation.isMuted ? 'unmute' : 'mute'),
                    ),
                  ),
                  LoomSettingsRow(
                    icon: LoomIcons.push_pin_outlined,
                    title: conversation.isPinned
                        ? tr(context, 'Unpin', 'برداشتن سنجاق')
                        : tr(context, 'Pin', 'سنجاق'),
                    trailing: Switch(
                      value: conversation.isPinned,
                      onChanged: (_) => unawaited(_run('pin')),
                    ),
                    onTap: () => unawaited(_run('pin')),
                  ),
                  LoomSettingsRow(
                    icon: LoomIcons.archive_outlined,
                    title: archived
                        ? tr(context, 'Unarchive', 'خروج از بایگانی')
                        : tr(context, 'Archive', 'بایگانی'),
                    onTap: () => unawaited(_run('archive')),
                  ),
                  LoomSettingsRow(
                    icon: LoomIcons.done_all,
                    title: tr(
                      context,
                      'Mark as unread',
                      'علامت‌گذاری خوانده‌نشده',
                    ),
                    onTap: () => unawaited(_run('unread')),
                  ),
                ],
              ),
              _sectionTitle(context, tr(context, 'Appearance', 'ظاهر')),
              LoomSettingsGroup(
                children: [
                  LoomSettingsRow(
                    icon: LoomIcons.wallpaper_rounded,
                    title: tr(context, 'Chat wallpaper', 'پس‌زمینهٔ گفتگو'),
                    subtitle: tr(
                      context,
                      'Color, gradient or photo',
                      'رنگ، گرادیان یا عکس',
                    ),
                    onTap: () => unawaited(_openWallpaper()),
                  ),
                  LoomSettingsRow(
                    icon: LoomIcons.palette_outlined,
                    title: tr(context, 'Global appearance', 'ظاهر کلی'),
                    subtitle: tr(
                      context,
                      'Theme, glass, motion',
                      'تم، شیشه، حرکت',
                    ),
                    onTap: () =>
                        Navigator.pushNamed(context, '/settings/appearance'),
                  ),
                ],
              ),
              if (!isGroup) ...[
                _sectionTitle(
                  context,
                  tr(context, 'On this device', 'روی این دستگاه'),
                ),
                LoomSettingsGroup(
                  children: [
                    LoomSettingsRow(
                      icon: LoomIcons.cleaning_services_outlined,
                      title: tr(
                        context,
                        'Clear local history',
                        'پاک کردن تاریخچهٔ محلی',
                      ),
                      onTap: () => unawaited(_run('clear')),
                    ),
                    LoomSettingsRow(
                      icon: LoomIcons.delete_outline_rounded,
                      iconColor: context.loom.critical,
                      title: tr(
                        context,
                        'Delete chat from this device',
                        'حذف گفتگو از این دستگاه',
                      ),
                      onTap: () => unawaited(_run('delete')),
                    ),
                  ],
                ),
              ],
              _sectionTitle(context, tr(context, 'About', 'درباره')),
              LoomSettingsGroup(
                children: [
                  LoomSettingsRow(
                    icon: LoomIcons.help_outline_rounded,
                    title: tr(
                      context,
                      'Message status guide',
                      'راهنمای وضعیت پیام',
                    ),
                    onTap: () => unawaited(_showDeliveryGuide(context)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _headerCard(BuildContext context, String title, bool isGroup) {
    return Padding(
      padding: const EdgeInsets.only(bottom: LoomSpacing.lg),
      child: Row(
        children: [
          LoomAvatar(
            label: title,
            size: 56,
          ),
          const SizedBox(width: LoomSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 2),
                Text(
                  isGroup
                      ? tr(context, 'Group conversation', 'گفتگوی گروهی')
                      : tr(context, 'Direct conversation', 'گفتگوی مستقیم'),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: context.loom.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(BuildContext context, String title) => Padding(
    padding: const EdgeInsets.only(
      left: LoomSpacing.sm,
      right: LoomSpacing.sm,
      bottom: LoomSpacing.sm,
    ),
    child: Text(title, style: Theme.of(context).textTheme.titleMedium),
  );

  Future<void> _run(String action) async {
    await _manageConversation(
      context,
      action,
      widget.conversation,
      widget.messaging,
    );
    if (mounted) setState(() {});
  }

  Future<void> _openWallpaper() async {
    final messaging = widget.messaging;
    await Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (_) => LoomWallpaperEditor(
          chatId:
              '${messaging.onboarding.committedIdentity?.identityId}:${widget.conversation.id}',
        ),
      ),
    );
  }
}
