import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter/services.dart';
import 'package:loom_design/loom_design.dart';
import 'package:loom_models/loom_models.dart';
import 'package:loom_protocol/loom_protocol.dart';
import 'package:flutter/material.dart';

import '../../../app/loom_strings.dart';
import '../application/groups_controller.dart';
import '../../messaging/application/messaging_session_controller.dart';
import 'group_join_screen.dart';
import 'group_create_screen.dart';
import 'group_photo_editor.dart';
import 'group_avatar.dart';
import 'group_attachment.dart';
import 'group_info_surface.dart';
import 'group_requests_screen.dart';
import '../../home/presentation/messenger_shell.dart';

Future<String?> showLoomNewGroup(BuildContext context) {
  final groups = LoomGroupsScope.of(context);
  return Navigator.of(context).push<String>(
    MaterialPageRoute<String>(
      builder: (_) => LoomGroupCreateScreen(groups: groups),
    ),
  );
}

class LoomGroupsScreen extends StatefulWidget {
  const LoomGroupsScreen({
    this.initialGroupId,
    this.managementOnly = false,
    super.key,
  });
  final bool managementOnly;
  final String? initialGroupId;
  @override
  State<LoomGroupsScreen> createState() => _LoomGroupsScreenState();
}

class _LoomGroupsScreenState extends State<LoomGroupsScreen>
    with WidgetsBindingObserver {
  LoomGroupsController? _groups;
  String? _selected;
  bool _opened = false;
  final _text = TextEditingController();
  final _focus = FocusNode();
  final _entering = <String>{};
  bool _uploading = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _selected = widget.initialGroupId;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_opened) return;
    _opened = true;
    final groups = LoomGroupsScope.of(context);
    _groups = groups;
    if (!widget.managementOnly) groups.setActiveGroup(_selected);
    _text.text = _selected == null ? '' : groups.draft(_selected!);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(groups.open());
    });
  }

  @override
  void dispose() {
    if (!widget.managementOnly) _groups?.setActiveGroup(null);
    WidgetsBinding.instance.removeObserver(this);
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (widget.managementOnly) return;
    _groups?.setActiveGroup(
      state == AppLifecycleState.resumed ? _selected : null,
    );
  }

  void _select(LoomGroupsController groups, String id) {
    if (_selected != null) groups.saveDraft(_selected!, _text.text);
    groups.setActiveGroup(id);
    _entering.clear();
    setState(() {
      _selected = id;
      _text.text = groups.draft(id);
    });
  }

  Future<void> _send(LoomGroupsController groups) async {
    final id = _selected, text = _text.text;
    if (id == null || groups.busy || text.trim().isEmpty) return;
    groups.saveDraft(id, text);
    final previous =
        groups.messages[id]?.map((m) => m.operationId).toSet() ?? <String>{};
    final sent = await groups.send(id, text);
    if (!mounted) return;
    if (sent) {
      _entering.addAll(
        (groups.messages[id] ?? [])
            .where(
              (m) =>
                  m.senderDeviceId == groups.ownDeviceId &&
                  !previous.contains(m.operationId),
            )
            .map((m) => m.operationId),
      );
      if (_selected == id && _text.text == text) _text.clear();
      setState(() {});
    }
    _focus.requestFocus();
  }

  Future<void> _create(LoomGroupsController groups) async {
    final id = await showLoomNewGroup(context);
    if (mounted && id != null) _select(groups, id);
  }

  Future<void> _members(
    LoomGroupsController groups,
    LoomGroupState group,
  ) => Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (_) =>
          LoomGroupsScreen(initialGroupId: group.id, managementOnly: true),
    ),
  );

  Future<bool> _confirm(String title, String detail, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(detail),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(tr(context, 'Cancel', 'لغو')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(action),
            ),
          ],
        ),
      ) ==
      true;

  Future<void> _memberAction(
    LoomGroupsController groups,
    LoomGroupState shown,
    LoomGroupMember member,
    String action,
  ) async {
    if (groups.busy) return;
    if (action == 'remove' &&
        !await _confirm(
          tr(context, 'Remove this member?', 'این عضو حذف شود؟'),
          tr(
            context,
            'They will not receive future group messages. Their existing history remains.',
            'این عضو پیام‌های بعدی گروه را دریافت نمی‌کند؛ تاریخچهٔ قبلی او باقی می‌ماند.',
          ),
          tr(context, 'Remove', 'حذف'),
        )) {
      return;
    }
    if (!mounted) return;
    if (action == 'owner' &&
        !await _confirm(
          tr(context, 'Transfer ownership?', 'مالکیت منتقل شود؟'),
          tr(
            context,
            'You will become an admin. The new owner can remove you from the group.',
            'شما مدیر می‌شوید و مالک جدید می‌تواند شما را از گروه حذف کند.',
          ),
          tr(context, 'Transfer', 'انتقال'),
        )) {
      return;
    }
    if (!mounted || groups.busy) return;
    final group = groups.groups.where((g) => g.id == shown.id).firstOrNull;
    if (group == null || group.revision != shown.revision) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            tr(
              context,
              'The member list changed. Review it and try again.',
              'فهرست اعضا تغییر کرده؛ آن را بررسی و دوباره تلاش کنید.',
            ),
          ),
        ),
      );
      return;
    }
    final own = group.members
        .where((m) => m.deviceId == groups.ownDeviceId)
        .firstOrNull;
    final target = group.members
        .where((m) => m.accountId == member.accountId)
        .firstOrNull;
    if (own == null ||
        own.role == 'member' ||
        target == null ||
        target.role == 'owner' ||
        target.accountId == own.accountId ||
        (['owner', 'admin', 'member'].contains(action) &&
            own.role != 'owner') ||
        (action == 'remove' &&
            target.role != 'member' &&
            own.role != 'owner') ||
        !['remove', 'owner', 'admin', 'member'].contains(action)) {
      return;
    }
    final members = action == 'remove'
        ? group.members.where((m) => m.accountId != member.accountId).toList()
        : group.members
              .map(
                (m) => LoomGroupMember(
                  accountId: m.accountId,
                  deviceId: m.deviceId,
                  identityId: m.identityId,
                  role: m.accountId == member.accountId
                      ? action
                      : action == 'owner' && m.role == 'owner'
                      ? 'admin'
                      : m.role,
                  mlsSignatureKey: m.mlsSignatureKey,
                  mlsSignature: m.mlsSignature,
                ),
              )
              .toList();
    await groups.update(
      group.id,
      group.title,
      members,
      expectedRevision: group.revision,
    );
  }

  Future<void> _rename(
    LoomGroupsController groups,
    LoomGroupState group,
  ) async {
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (c) => LoomAsyncTextDialog(
        title: tr(c, 'Edit group name', 'ویرایش نام گروه'),
        label: tr(c, 'Group name', 'نام گروه'),
        initialValue: group.title,
        maxLength: 100,
        actionLabel: tr(c, 'Save', 'ذخیره'),
        cancelLabel: tr(c, 'Cancel', 'لغو'),
        failureLabel: tr(
          c,
          'The name could not be saved. Check your connection and try again.',
          'نام ذخیره نشد. اتصال را بررسی و دوباره تلاش کنید.',
        ),
        validator: (value) => value == null || value.trim().isEmpty
            ? tr(c, 'Enter a group name.', 'نام گروه را وارد کنید.')
            : null,
        onSubmit: (title) => title == group.title
            ? Future.value(true)
            : groups.update(
                group.id,
                title,
                group.members,
                expectedRevision: group.revision,
              ),
      ),
    );
  }

  Future<void> _addMember(
    LoomGroupsController groups,
    LoomGroupState group,
  ) async {
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (c) => LoomAsyncTextDialog(
        title: tr(c, 'Add by username', 'افزودن با نام کاربری'),
        label: tr(c, 'Username or address', 'نام کاربری یا آدرس'),
        hint: '@name:home.example',
        textDirection: TextDirection.ltr,
        actionLabel: tr(c, 'Add', 'افزودن'),
        cancelLabel: tr(c, 'Cancel', 'لغو'),
        failureLabel: tr(
          c,
          'This member could not be added. Check the username and connection, then try again.',
          'عضو اضافه نشد. نام کاربری و اتصال را بررسی و دوباره تلاش کنید.',
        ),
        validator: (value) {
          try {
            final home = groups.onboarding.receipt?.homeNode;
            if (home == null ||
                value == null ||
                value.trim().isEmpty ||
                !LoomAddress.normalizeInput(
                  value,
                  homeNode: home,
                ).isSameNode(home)) {
              return tr(
                c,
                'Enter a username on your server.',
                'نام کاربری در سرور خود وارد کنید.',
              );
            }
          } on FormatException {
            return tr(
              c,
              'Enter a valid username or address.',
              'نام کاربری یا آدرس معتبر وارد کنید.',
            );
          }
          return null;
        },
        onSubmit: (address) => groups.addContact(group.id, address),
      ),
    );
  }

  Future<void> _openMember(
    LoomGroupsController groups,
    LoomGroupMember member,
  ) async {
    try {
      final address = await groups.memberAddress(member);
      if (!mounted) return;
      final messaging = LoomMessagingSessionScope.of(context);
      final conversation = await messaging.startConversation(address);
      if (!mounted) return;
      if (conversation == null) {
        throw StateError(messaging.errorMessage ?? 'Unable to open chat');
      }
      if (!widget.managementOnly) groups.setActiveGroup(null);
      await Navigator.of(
        context,
      ).pushNamed('/messenger', arguments: conversation.id);
      if (mounted && !widget.managementOnly) groups.setActiveGroup(_selected);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              tr(
                context,
                'Unable to open private chat. Reconnect and try again.',
                'چت خصوصی باز نشد؛ اتصال را بررسی و دوباره تلاش کنید.',
              ),
            ),
          ),
        );
      }
    }
  }

  Future<void> _invite(
    LoomGroupsController groups,
    LoomGroupState group,
  ) async {
    final choice = await showLoomActionSheet<String>(
      context: context,
      title: tr(context, 'Invite link', 'لینک دعوت'),
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          LoomDetailTile(
            leading: const Icon(LoomIcons.link),
            title: Text(tr(context, 'Anyone with the link can join', 'عضویت آزاد با لینک')),
            onTap: () => Navigator.pop(context, 'open'),
          ),
          LoomDetailTile(
            leading: const Icon(LoomIcons.people_outline_rounded),
            title: Text(tr(context, 'Administrator approval required', 'عضویت با تأیید مدیر')),
            onTap: () => Navigator.pop(context, 'approval'),
          ),
          LoomDetailTile(
            leading: Icon(LoomIcons.close_rounded, color: context.loom.critical),
            title: Text(tr(context, 'Revoke invitation links', 'لغو لینک‌های دعوت')),
            onTap: () => Navigator.pop(context, 'revoke'),
          ),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == 'revoke') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(
            tr(context, 'Revoke invitation links?', 'لینک‌های دعوت لغو شوند؟'),
          ),
          content: Text(
            tr(
              context,
              'Existing members stay. Unfinished requests using these links cannot join.',
              'اعضای فعلی می‌مانند؛ درخواست‌های تکمیل‌نشده با این لینک‌ها دیگر پذیرفته نمی‌شوند.',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(tr(context, 'Cancel', 'لغو')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(tr(context, 'Revoke', 'لغو لینک')),
            ),
          ],
        ),
      );
      if (confirmed == true) await groups.revokeInvites(group.id);
      return;
    }
    final link = await groups.createInvite(group.id, choice);
    if (!mounted || link == null) return;
    await showDialog<void>(
      context: context,
      builder: (context) => LoomGlassDialog(
        title: tr(context, 'Group invitation', 'دعوت به گروه'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(tr(context, 'Close', 'بستن')),
          ),
          FilledButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: link));
              if (context.mounted) Navigator.pop(context);
            },
            icon: const Icon(LoomIcons.copy_outlined),
            label: Text(tr(context, 'Copy link', 'کپی لینک')),
          ),
        ],
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              tr(
                context,
                'Valid for 7 days. Creating another link replaces this one.',
                'اعتبار ۷ روز؛ ساخت لینک جدید، این لینک را لغو می‌کند.',
              ),
            ),
            const SizedBox(height: 12),
            LoomGlassSurface(
              padding: const EdgeInsets.all(16),
              child: SelectableText(link, textDirection: TextDirection.ltr),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _requests(
    LoomGroupsController groups,
    LoomGroupState group,
  ) async {
    await groups.open();
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => LoomGroupRequestsScreen(groupId: group.id),
      ),
    );
  }

  Future<void> _attach(LoomGroupsController groups, String id) async {
    final send = groups.sendAttachment;
    if (send == null || _uploading) return;
    final kind = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final entry in [
              ('image', LoomIcons.photo_library_outlined, 'Photo', 'تصویر'),
              ('video', LoomIcons.videocam_outlined, 'Video', 'ویدیو'),
              ('audio', LoomIcons.music_note_outlined, 'Audio', 'صوت'),
              ('file', LoomIcons.attach_file_rounded, 'File', 'فایل'),
            ])
              ListTile(
                leading: Icon(entry.$2),
                title: Text(tr(context, entry.$3, entry.$4)),
                onTap: () => Navigator.pop(context, entry.$1),
              ),
          ],
        ),
      ),
    );
    if (kind == null || !mounted) return;
    setState(() => _uploading = true);
    try {
      final XFile? selected = switch (kind) {
        'image' => await ImagePicker().pickImage(source: ImageSource.gallery),
        'video' => await ImagePicker().pickVideo(source: ImageSource.gallery),
        'audio' => await openFile(
          acceptedTypeGroups: [
            const XTypeGroup(
              label: 'Audio',
              extensions: ['mp3', 'm4a', 'ogg', 'wav', 'flac', 'aac'],
              mimeTypes: ['audio/*'],
            ),
          ],
        ),
        _ => await openFile(),
      };
      if (selected == null || !mounted) return;
      final previous =
          groups.messages[id]?.map((m) => m.operationId).toSet() ?? <String>{};
      final caption = _text.text;
      final sent = await send(id, File(selected.path), kind, caption);
      if (!mounted) return;
      if (sent) {
        _entering.addAll(
          (groups.messages[id] ?? [])
              .where(
                (m) =>
                    m.senderDeviceId == groups.ownDeviceId &&
                    !previous.contains(m.operationId),
              )
              .map((m) => m.operationId),
        );
        if (_selected == id && _text.text == caption) _text.clear();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              tr(
                context,
                'Attachment was not sent. Check the server file limit and retry.',
                'فایل ارسال نشد؛ محدودیت حجم سرور را بررسی و دوباره تلاش کنید.',
              ),
            ),
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              tr(
                context,
                'Unable to read this file',
                'خواندن این فایل ممکن نیست',
              ),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final groups = LoomGroupsScope.of(context);
    final group = groups.groups.where((g) => g.id == _selected).firstOrNull;
    final narrow = MediaQuery.sizeOf(context).width < 900;
    void backToList() {
      if (_selected != null) groups.saveDraft(_selected!, _text.text);
      groups.setActiveGroup(null);
      setState(() => _selected = null);
    }

    if (widget.managementOnly) {
      if (group == null) {
        return Scaffold(
          appBar: LoomGlassAppBar(
            title: Text(tr(context, 'Group info', 'اطلاعات گروه')),
          ),
          body: Center(
            child: groups.busy
                ? const CircularProgressIndicator()
                : Text(
                    tr(
                      context,
                      'This group is no longer available.',
                      'این گروه دیگر در دسترس نیست.',
                    ),
                  ),
          ),
        );
      }
      final messaging = LoomMessagingSessionScope.maybeOf(context);
      final conversation = messaging?.conversations
          .where((c) => c.id == group.id)
          .firstOrNull;
      return LoomGroupInfoSurface(
        groups: groups,
        group: group,
        onOpenMember: (member) => unawaited(_openMember(groups, member)),
        onMemberAction: (member, action) =>
            unawaited(_memberAction(groups, group, member, action)),
        onAddMember: () => unawaited(_addMember(groups, group)),
        onInvite: () => unawaited(_invite(groups, group)),
        onRequests: () => unawaited(_requests(groups, group)),
        onRename: () => unawaited(_rename(groups, group)),
        onPhoto: () => unawaited(
          showDialog<void>(
            context: context,
            barrierDismissible: false,
            builder: (_) => LoomGroupPhotoEditor(
              groups: groups,
              groupId: group.id,
              title: group.title,
            ),
          ),
        ),
        muted: conversation?.isMuted ?? false,
        onNotifications: messaging == null || conversation == null
            ? null
            : () => unawaited(
                messaging.setConversationMuted(group.id, !conversation.isMuted),
              ),
        onMedia: messaging == null
            ? null
            : () => Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      LoomConversationMediaScreen(conversationId: group.id),
                ),
              ),
      );
    }
    if (group != null && LoomMessagingSessionScope.maybeOf(context) != null) {
      return Scaffold(
        body: LoomConversationSurface(
          conversationId: group.id,
          onBack: backToList,
        ),
      );
    }
    return PopScope(
      canPop: !narrow || _selected == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) backToList();
      },
      child: Scaffold(
        appBar: LoomGlassAppBar(
          leading: narrow && _selected != null
              ? BackButton(onPressed: backToList)
              : null,
          title: Text(group?.title ?? tr(context, 'Groups', 'گروه‌ها')),
          actions: [
            IconButton(
              onPressed: groups.busy
                  ? null
                  : () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const LoomGroupJoinScreen(),
                      ),
                    ),
              icon: const Icon(LoomIcons.link),
              tooltip: tr(context, 'Join with link', 'عضویت با لینک'),
            ),
            if (group != null)
              IconButton(
                onPressed: groups.busy ? null : () => _members(groups, group),
                icon: const Icon(LoomIcons.people_outline_rounded),
                tooltip: tr(context, 'Members', 'اعضا'),
              ),
            IconButton(
              onPressed: groups.busy ? null : () => groups.open(),
              icon: const Icon(LoomIcons.refresh_rounded),
              tooltip: tr(context, 'Sync', 'همگام‌سازی'),
            ),
            IconButton(
              onPressed: groups.busy ? null : () => _create(groups),
              icon: const Icon(LoomIcons.add_rounded),
              tooltip: tr(context, 'New group', 'گروه جدید'),
            ),
          ],
        ),
        body: Column(
          children: [
            if (groups.busy) const LinearProgressIndicator(minHeight: 2),
            if (groups.error != null)
              MaterialBanner(
                content: Text(groups.error!),
                actions: [
                  TextButton(
                    onPressed: groups.busy ? null : () => groups.open(),
                    child: Text(tr(context, 'Retry', 'تلاش مجدد')),
                  ),
                ],
              ),
            if (groups.pendingCount > 0)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  tr(
                    context,
                    'Encrypted delivery pending; reconnect to retry.',
                    'ارسال رمزگذاری‌شده در انتظار است؛ برای تلاش مجدد متصل شوید.',
                  ),
                ),
              ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, size) {
                  final catalogue = ListView(
                    children: [
                      if (groups.groups.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            tr(
                              context,
                              'No groups yet. Create a group or sync an invitation after verifying its members.',
                              'هنوز گروهی ندارید. گروه بسازید یا پس از تأیید اعضا، دعوت را همگام کنید.',
                            ),
                          ),
                        ),
                      for (final item in groups.groups)
                        ListTile(
                          selected: _selected == item.id,
                          leading: LoomGroupAvatar(
                            groupId: item.id,
                            label: item.title,
                            groups: groups,
                          ),
                          title: Text(item.title),
                          trailing: (groups.unreadCounts[item.id] ?? 0) > 0
                              ? Badge(
                                  label: Text(
                                    '${groups.unreadCounts[item.id]}',
                                  ),
                                )
                              : null,
                          subtitle: Text(
                            tr(
                              context,
                              '${item.members.map((m) => m.accountId).toSet().length} members · encrypted',
                              '${item.members.map((m) => m.accountId).toSet().length} عضو · رمزگذاری‌شده',
                            ),
                          ),
                          onTap: () => _select(groups, item.id),
                        ),
                    ],
                  );
                  if (group == null) return catalogue;
                  final rows =
                      groups.messages[group.id] ?? const <LoomGroupMessage>[];
                  final member = group.members.any(
                    (m) => m.deviceId == groups.ownDeviceId,
                  );
                  final chat = Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(8),
                        child: Text(
                          member
                              ? tr(
                                  context,
                                  'End-to-end encrypted with MLS',
                                  'رمزگذاری سرتاسری با MLS',
                                )
                              : tr(
                                  context,
                                  'This device was removed. History is read-only.',
                                  'این دستگاه حذف شده؛ تاریخچه فقط خواندنی است.',
                                ),
                        ),
                      ),
                      Expanded(
                        child: ListView.builder(
                          reverse: true,
                          padding: const EdgeInsets.all(16),
                          itemCount: rows.length,
                          itemBuilder: (context, index) {
                            final message = rows[rows.length - index - 1],
                                own =
                                    message.senderDeviceId ==
                                    groups.ownDeviceId;
                            return LoomSendReveal(
                              key: ValueKey(
                                '${group.id}:${message.operationId}',
                              ),
                              animate:
                                  own &&
                                  _entering.contains(message.operationId),
                              onEnd: () =>
                                  _entering.remove(message.operationId),
                              child: Align(
                                alignment: own
                                    ? AlignmentDirectional.centerEnd
                                    : AlignmentDirectional.centerStart,
                                child: ConstrainedBox(
                                  constraints: const BoxConstraints(
                                    maxWidth: 560,
                                  ),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 5,
                                    ),
                                    child: LoomGlassSurface(
                                      radius: 16,
                                      padding: const EdgeInsets.all(12),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          if (!own)
                                            Text(
                                              groups.senderLabel(
                                                message.senderDeviceId,
                                              ),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: Theme.of(
                                                context,
                                              ).textTheme.labelSmall,
                                            ),
                                          if (message.attachment != null)
                                            LoomGroupAttachment(
                                              media: message.attachment!,
                                              home: groups
                                                  .onboarding
                                                  .nodes
                                                  .selectedEndpoint!
                                                  .host,
                                            ),
                                          if (message.text.isNotEmpty)
                                            SelectableText(message.text),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                      if (member)
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: LoomGlassComposer(
                            controller: _text,
                            focusNode: _focus,
                            sending: _uploading || groups.busy,
                            hintText: tr(context, 'Message', 'پیام'),
                            attachTooltip: tr(context, 'Attach file or media', 'ارسال فایل یا مدیا'),
                            voiceTooltip: tr(context, 'Voice message', 'پیام صوتی'),
                            sendTooltip: tr(context, 'Send', 'ارسال'),
                            onChanged: (value) => groups.saveDraft(group.id, value),
                            onSend: groups.ready && !groups.busy && !_uploading ? () => _send(groups) : null,
                            onAttach: groups.ready && !groups.busy && !_uploading && groups.sendAttachment != null ? () => _attach(groups, group.id) : null,
                          ),
                        ),
                    ],
                  );
                  if (size.maxWidth < 900) return chat;
                  return Row(
                    children: [
                      SizedBox(width: 280, child: catalogue),
                      const VerticalDivider(width: 1),
                      Expanded(child: chat),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
