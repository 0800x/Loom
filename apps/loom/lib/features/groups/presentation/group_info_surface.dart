import 'dart:async';

import 'package:loom_design/loom_design.dart';
import 'package:loom_models/loom_models.dart';
import 'package:flutter/material.dart';

import '../../../app/loom_strings.dart';
import '../application/groups_controller.dart';
import 'group_avatar.dart';

/// Account-oriented group details. Device credentials stay in the controller;
/// they are never presented as duplicate people or invented presence states.
class LoomGroupInfoSurface extends StatefulWidget {
  const LoomGroupInfoSurface({
    required this.groups,
    required this.group,
    required this.onOpenMember,
    required this.onMemberAction,
    required this.onAddMember,
    required this.onInvite,
    required this.onRequests,
    required this.onRename,
    this.onMedia,
    this.onPhoto,
    this.onNotifications,
    this.muted = false,
    super.key,
  });
  final LoomGroupsController groups;
  final LoomGroupState group;
  final void Function(LoomGroupMember) onOpenMember;
  final void Function(LoomGroupMember, String) onMemberAction;
  final VoidCallback onAddMember, onInvite, onRequests, onRename;
  final VoidCallback? onMedia, onNotifications, onPhoto;
  final bool muted;

  @override
  State<LoomGroupInfoSurface> createState() => _LoomGroupInfoSurfaceState();
}

class _LoomGroupInfoSurfaceState extends State<LoomGroupInfoSurface> {
  final _search = TextEditingController();
  String _query = '';
  bool _adminsOnly = false;
  final _loaded = <String>{};

  @override
  void initState() {
    super.initState();
    _loadProfiles();
  }

  @override
  void didUpdateWidget(LoomGroupInfoSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.group.id != widget.group.id) {
      _loaded.clear();
      _search.clear();
      _query = '';
      _adminsOnly = false;
    }
    _loadProfiles();
  }

  void _loadProfiles({bool force = false}) {
    final members = widget.group.members
        .where((m) => _loaded.add('${m.identityId}:${m.deviceId}'))
        .toList();
    if (members.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(widget.groups.loadMemberProfiles(members, force: force));
      }
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  int _rank(String role) => switch (role) {
    'owner' => 0,
    'admin' => 1,
    _ => 2,
  };

  String _role(BuildContext context, String role) => switch (role) {
    'owner' => tr(context, 'Owner', 'مالک'),
    'admin' => tr(context, 'Admin', 'مدیر'),
    _ => tr(context, 'Member', 'عضو'),
  };

  @override
  Widget build(BuildContext context) {
    final groups = widget.groups, group = widget.group;
    final own = group.members
        .where((m) => m.deviceId == groups.ownDeviceId)
        .firstOrNull;
    final admin = own != null && own.role != 'member';
    final owner = own?.role == 'owner';
    final pendingRequests = (groups.joinRequests[group.id] ?? const [])
        .where((r) => r['status'] == 'pending')
        .map((r) => (r['member'] as Map)['accountId'])
        .toSet()
        .length;
    final people = <String, LoomGroupMember>{};
    for (final member in group.members) {
      final previous = people[member.accountId];
      if (previous == null || _rank(member.role) < _rank(previous.role)) {
        people[member.accountId] = member;
      }
    }
    final admins = people.values.where((m) => m.role != 'member').length;
    final visible =
        people.values.where((m) {
          if (_adminsOnly && m.role == 'member') return false;
          final label = groups.memberLabel(m),
              address = groups.memberCachedAddress(m);
          return _query.isEmpty ||
              '$label ${address ?? ''} ${m.accountId == groups.ownAccountId ? tr(context, 'You', 'شما') : ''}'
                  .toLowerCase()
                  .contains(_query);
        }).toList()..sort((a, b) {
          final role = _rank(a.role).compareTo(_rank(b.role));
          return role != 0
              ? role
              : groups
                    .memberLabel(a)
                    .toLowerCase()
                    .compareTo(groups.memberLabel(b).toLowerCase());
        });

    return Scaffold(
      backgroundColor: context.loom.background,
      appBar: LoomGlassAppBar(
        title: Text(tr(context, 'Group info', 'اطلاعات گروه')),
        actions: [
          if (admin)
            IconButton(
              tooltip: tr(context, 'Edit group name', 'ویرایش نام گروه'),
              onPressed: groups.busy ? null : widget.onRename,
              icon: const Icon(LoomIcons.edit_outlined),
            ),
        ],
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: LoomSizing.detailsMax),
          child: RefreshIndicator(
            onRefresh: () async {
              await groups.synchronize();
              if (!mounted) return;
              _loaded.clear();
              _loadProfiles(force: true);
            },
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
                  sliver: SliverToBoxAdapter(
                    child: LoomGlassSurface(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                      children: [
                        LoomGroupAvatar(
                          groupId: group.id,
                          label: group.title,
                          size: 92,
                          groups: groups,
                        ),
                        if (admin && widget.onPhoto != null)
                          TextButton.icon(
                            onPressed: groups.busy ? null : widget.onPhoto,
                            icon: const Icon(
                              LoomIcons.photo_library_outlined,
                            ),
                            label: Text(
                              tr(
                                context,
                                'Edit group photo',
                                'ویرایش تصویر گروه',
                              ),
                            ),
                          ),
                        const SizedBox(height: 16),
                        Text(
                          group.title,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '${people.length} ${tr(context, 'members', 'عضو')}',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                        const SizedBox(height: 20),
                        Wrap(
                          alignment: WrapAlignment.center,
                          spacing: 12,
                          runSpacing: 8,
                          children: [
                            if (admin)
                              FilledButton.icon(
                                onPressed: groups.busy
                                    ? null
                                    : widget.onAddMember,
                                icon: const Icon(
                                  LoomIcons.person_add_alt_rounded,
                                ),
                                label: Text(
                                  tr(context, 'Add members', 'افزودن اعضا'),
                                ),
                              ),
                            if (admin)
                              OutlinedButton.icon(
                                onPressed: groups.busy ? null : widget.onInvite,
                                icon: const Icon(LoomIcons.link),
                                label: Text(
                                  tr(context, 'Invite link', 'لینک دعوت'),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 20),
                        LoomSettingsGroup(
                          children: [
                            if (widget.onNotifications != null)
                              LoomSettingsRow(
                                icon: widget.muted
                                    ? LoomIcons.notifications_off_outlined
                                    : LoomIcons.notifications_none_rounded,
                                title: tr(context, 'Notifications', 'اعلان‌ها'),
                                subtitle: widget.muted
                                    ? tr(context, 'Off', 'خاموش')
                                    : tr(context, 'On', 'روشن'),
                                onTap: widget.onNotifications,
                              ),
                            if (widget.onMedia != null)
                              LoomSettingsRow(
                                icon: LoomIcons.photo_library_outlined,
                                title: tr(
                                  context,
                                  'Shared media',
                                  'رسانه‌های مشترک',
                                ),
                                onTap: widget.onMedia,
                                showDivider: admin,
                              ),
                            if (admin)
                              LoomSettingsRow(
                                icon: LoomIcons.person_add_alt_rounded,
                                title: tr(
                                  context,
                                  'Join requests',
                                  'درخواست‌های عضویت',
                                ),
                                subtitle: '$pendingRequests',
                                onTap: groups.busy ? null : widget.onRequests,
                                showDivider: false,
                              ),
                          ],
                        ),
                        if (groups.busy) const LinearProgressIndicator(),
                        if (groups.error != null)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: Text(
                              tr(
                                context,
                                'The change could not be completed. Pull down to refresh and try again.',
                                'تغییر انجام نشد. برای تازه‌سازی صفحه را پایین بکشید و دوباره تلاش کنید.',
                              ),
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          ),
                        const SizedBox(height: 20),
                        Row(
                          children: [
                            Expanded(
                              child: _tab(
                                context,
                                '${tr(context, 'Members', 'اعضا')} (${people.length})',
                                false,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: _tab(
                                context,
                                '${tr(context, 'Administrators', 'مدیرها')} ($admins)',
                                true,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          key: const ValueKey('group-member-search'),
                          controller: _search,
                          onChanged: (value) => setState(
                            () => _query = value.trim().toLowerCase(),
                          ),
                          decoration: InputDecoration(
                            hintText: tr(
                              context,
                              'Search members',
                              'جست‌وجوی اعضا',
                            ),
                            prefixIcon: const Icon(LoomIcons.search_rounded),
                            suffixIcon: _query.isEmpty
                                ? null
                                : IconButton(
                                    tooltip: tr(
                                      context,
                                      'Clear search',
                                      'پاک کردن جست‌وجو',
                                    ),
                                    icon: const Icon(LoomIcons.close_rounded),
                                    onPressed: () => setState(() {
                                      _search.clear();
                                      _query = '';
                                    }),
                                  ),
                          ),
                        ),
                        const SizedBox(height: 8),
                      ],
                    ),
                    ),
                  ),
                ),
                if (visible.isEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Center(
                        child: Text(
                          tr(context, 'No members found', 'عضوی پیدا نشد'),
                        ),
                      ),
                    ),
                  ),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 24),
                  sliver: SliverList.builder(
                    itemCount: visible.length,
                    itemBuilder: (context, index) {
                      final member = visible[index];
                      final self = member.accountId == groups.ownAccountId;
                      final name = self
                          ? tr(context, 'You', 'شما')
                          : groups.memberLabel(member);
                      final address = groups.memberCachedAddress(member);
                      return LoomDetailTile(
                        key: ValueKey('group-member-${member.accountId}'),
                        leading: LoomAvatar(label: name, size: 44),
                        title: Text(
                          name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: address == null
                            ? null
                            : Text(
                                address,
                                textDirection: TextDirection.ltr,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                        onTap: self || groups.busy
                            ? null
                            : () => widget.onOpenMember(member),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (member.role != 'member')
                              Text(
                                _role(context, member.role),
                                style: TextStyle(
                                  color: context.loom.primary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            if (!self)
                              PopupMenuButton<String>(
                                tooltip: tr(
                                  context,
                                  'Member options',
                                  'گزینه‌های عضو',
                                ),
                                enabled: !groups.busy,
                                onSelected: (value) => value == 'chat'
                                    ? widget.onOpenMember(member)
                                    : widget.onMemberAction(member, value),
                                itemBuilder: (context) => [
                                  PopupMenuItem(
                                    value: 'chat',
                                    child: Text(
                                      tr(context, 'Send message', 'ارسال پیام'),
                                    ),
                                  ),
                                  if (owner && member.role != 'owner')
                                    PopupMenuItem(
                                      value: member.role == 'admin'
                                          ? 'member'
                                          : 'admin',
                                      child: Text(
                                        member.role == 'admin'
                                            ? tr(
                                                context,
                                                'Remove admin role',
                                                'برداشتن نقش مدیر',
                                              )
                                            : tr(
                                                context,
                                                'Make admin',
                                                'تبدیل به مدیر',
                                              ),
                                      ),
                                    ),
                                  if (admin &&
                                      (owner || member.role == 'member') &&
                                      member.role != 'owner')
                                    PopupMenuItem(
                                      value: 'remove',
                                      child: Text(
                                        tr(context, 'Remove member', 'حذف عضو'),
                                      ),
                                    ),
                                  if (owner)
                                    PopupMenuItem(
                                      value: 'owner',
                                      child: Text(
                                        tr(
                                          context,
                                          'Transfer ownership',
                                          'انتقال مالکیت',
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _tab(BuildContext context, String label, bool admins) => TextButton(
    key: ValueKey(admins ? 'group-admins-tab' : 'group-members-tab'),
    style: TextButton.styleFrom(
      backgroundColor: _adminsOnly == admins
          ? context.loom.primary.withAlphaFraction(.12)
          : null,
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
    ),
    onPressed: () => setState(() => _adminsOnly = admins),
    child: Text(label, textAlign: TextAlign.center),
  );
}
