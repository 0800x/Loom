import 'dart:async';

import 'package:loom_design/loom_design.dart';
import 'package:loom_models/loom_models.dart';
import 'package:flutter/material.dart';

import '../../../app/loom_strings.dart';
import '../application/groups_controller.dart';
import 'group_avatar.dart';

/// Account-oriented group details. Device credentials stay in the controller;
/// they are never presented as duplicate people or invented presence states.
///
/// Layout follows the flat Telegram pattern: a centred hero, circular tinted
/// quick actions, grouped setting cards and one continuous members card with
/// inset dividers and role pills.
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
    this.onLeave,
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

  /// Leave (member) / delete-and-leave (owner) affordance; null hides the row.
  final VoidCallback? onLeave;
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

  @override
  Widget build(BuildContext context) {
    final p = context.loom;
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
      backgroundColor: p.background,
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
                // Flat hero: avatar, title, member count, circular actions.
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
                    child: Column(
                      children: [
                        LoomGroupAvatar(
                          groupId: group.id,
                          label: group.title,
                          size: 92,
                          groups: groups,
                        ),
                        const SizedBox(height: 14),
                        Text(
                          group.title,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          tr(
                            context,
                            '${people.length} members',
                            '${people.length} عضو',
                          ),
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(color: p.textSecondary),
                        ),
                        const SizedBox(height: 18),
                        // Scrollable so four actions stay reachable at 320px.
                        Builder(
                          builder: (context) {
                            final actions = <Widget>[
                              if (admin)
                                _GroupAction(
                                  icon: LoomIcons.person_add_alt_rounded,
                                  label: tr(
                                    context,
                                    'Add members',
                                    'افزودن اعضا',
                                  ),
                                  enabled: !groups.busy,
                                  onTap: widget.onAddMember,
                                ),
                              if (admin)
                                _GroupAction(
                                  icon: LoomIcons.link,
                                  label: tr(
                                    context,
                                    'Invite link',
                                    'لینک دعوت',
                                  ),
                                  enabled: !groups.busy,
                                  onTap: widget.onInvite,
                                ),
                              if (admin && widget.onPhoto != null)
                                _GroupAction(
                                  icon: LoomIcons.photo_library_outlined,
                                  label: tr(
                                    context,
                                    'Group photo',
                                    'تصویر گروه',
                                  ),
                                  enabled: !groups.busy,
                                  onTap: widget.onPhoto!,
                                ),
                              if (widget.onNotifications != null)
                                _GroupAction(
                                  icon: widget.muted
                                      ? LoomIcons.notifications_off_outlined
                                      : LoomIcons.notifications_none_rounded,
                                  label: widget.muted
                                      ? tr(context, 'Unmute', 'قطع بی‌صدا')
                                      : tr(context, 'Mute', 'بی‌صدا'),
                                  enabled: true,
                                  onTap: widget.onNotifications!,
                                ),
                            ];
                            return SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: Row(
                                children: [
                                  for (var i = 0; i < actions.length; i++) ...[
                                    if (i > 0) const SizedBox(width: 16),
                                    actions[i],
                                  ],
                                ],
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ),
                if (groups.busy)
                  const SliverToBoxAdapter(
                    child: LinearProgressIndicator(minHeight: 2),
                  ),
                if (groups.error != null)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                      child: Material(
                        color: p.critical.withValues(alpha: .08),
                        borderRadius: BorderRadius.circular(12),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(
                            tr(
                              context,
                              'The change could not be completed. Pull down to refresh and try again.',
                              'تغییر انجام نشد. برای تازه‌سازی صفحه را پایین بکشید و دوباره تلاش کنید.',
                            ),
                            style: TextStyle(color: p.critical, fontSize: 13),
                          ),
                        ),
                      ),
                    ),
                  ),
                // Group settings card.
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
                  sliver: SliverToBoxAdapter(
                    child: LoomSettingsGroup(
                      children: [
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
                            subtitle: pendingRequests > 0
                                ? tr(
                                    context,
                                    '$pendingRequests pending',
                                    '$pendingRequests در انتظار',
                                  )
                                : tr(context, 'None', 'هیچ'),
                            trailing: pendingRequests > 0 ? _Dot() : null,
                            onTap: groups.busy ? null : widget.onRequests,
                            showDivider: false,
                          ),
                      ],
                    ),
                  ),
                ),
                // Members header: pills + search.
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 22, 16, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Wrap (not a horizontal scroller): nested horizontal
                        // scrollables break Scrollable.ensureVisible targeting
                        // in the outer list and the pills overflow at 320px.
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            _MemberPill(
                              key: const ValueKey('group-members-tab'),
                              label: tr(context, 'Members', 'اعضا'),
                              count: people.length,
                              selected: !_adminsOnly,
                              onTap: () => setState(() => _adminsOnly = false),
                            ),
                            _MemberPill(
                              key: const ValueKey('group-admins-tab'),
                              label: tr(context, 'Administrators', 'مدیرها'),
                              count: admins,
                              selected: _adminsOnly,
                              onTap: () => setState(() => _adminsOnly = true),
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
                            prefixIcon: const Icon(
                              LoomIcons.search_rounded,
                              size: 20,
                            ),
                            isDense: true,
                            suffixIcon: _query.isEmpty
                                ? null
                                : IconButton(
                                    tooltip: tr(
                                      context,
                                      'Clear search',
                                      'پاک کردن جست‌وجو',
                                    ),
                                    icon: const Icon(
                                      LoomIcons.close_rounded,
                                      size: 18,
                                    ),
                                    onPressed: () => setState(() {
                                      _search.clear();
                                      _query = '';
                                    }),
                                  ),
                          ),
                        ),
                      ],
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
                          style: TextStyle(color: p.textSecondary),
                        ),
                      ),
                    ),
                  )
                else
                  // Lazy SliverList styled as one continuous card: the first
                  // and last rows carry the rounded corners.
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    sliver: SliverList.builder(
                      itemCount: visible.length,
                      itemBuilder: (context, index) {
                        return _MemberRow(
                          key: ValueKey(
                            'group-member-${visible[index].accountId}',
                          ),
                          groups: groups,
                          member: visible[index],
                          owner: owner,
                          admin: admin,
                          isFirst: index == 0,
                          isLast: index == visible.length - 1,
                          showDivider: index < visible.length - 1,
                          onOpenMember: widget.onOpenMember,
                          onMemberAction: widget.onMemberAction,
                        );
                      },
                    ),
                  ),
                if (widget.onLeave != null && !groups.busy)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                      child: Center(
                        child: TextButton.icon(
                          key: const ValueKey('group-leave'),
                          onPressed: widget.onLeave,
                          icon: Icon(
                            LoomIcons.logout_rounded,
                            size: LoomIconSize.compact,
                            color: p.critical,
                          ),
                          label: Text(
                            tr(
                              context,
                              owner ? 'Delete and leave group' : 'Leave group',
                              owner ? 'حذف گروه و خروج' : 'خروج از گروه',
                            ),
                            style: TextStyle(color: p.critical),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Circular tinted quick action, matching the profile screens.
class _GroupAction extends StatelessWidget {
  const _GroupAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.enabled = true,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final p = context.loom;
    return Opacity(
      opacity: enabled ? 1 : .45,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Material(
            color: p.primary.withValues(alpha: .10),
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: enabled ? onTap : null,
              child: SizedBox.square(
                dimension: 52,
                child: Icon(icon, size: 23, color: p.primary),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.labelMedium?.copyWith(color: p.primary),
          ),
        ],
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Container(
    width: 9,
    height: 9,
    decoration: BoxDecoration(
      color: context.loom.primary,
      shape: BoxShape.circle,
    ),
  );
}

/// Flat pill filter for the member list (Members / Administrators).
class _MemberPill extends StatelessWidget {
  const _MemberPill({
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.loom;
    return Material(
      color: selected ? p.primary : p.primary.withValues(alpha: .08),
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Text(
            '$label $count',
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: selected ? Colors.white : p.textPrimary,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

/// One flat member row: avatar, name + address, role pill and the overflow
/// menu; rows stack into a continuous card with inset dividers.
class _MemberRow extends StatelessWidget {
  const _MemberRow({
    required this.groups,
    required this.member,
    required this.owner,
    required this.admin,
    required this.isFirst,
    required this.isLast,
    required this.showDivider,
    required this.onOpenMember,
    required this.onMemberAction,
    super.key,
  });

  final LoomGroupsController groups;
  final LoomGroupMember member;
  final bool owner, admin, isFirst, isLast, showDivider;
  final void Function(LoomGroupMember) onOpenMember;
  final void Function(LoomGroupMember, String) onMemberAction;

  String _role(BuildContext context, String role) => switch (role) {
    'owner' => tr(context, 'Owner', 'مالک'),
    'admin' => tr(context, 'Admin', 'مدیر'),
    _ => tr(context, 'Member', 'عضو'),
  };

  @override
  Widget build(BuildContext context) {
    final p = context.loom;
    final self = member.accountId == groups.ownAccountId;
    final name = self ? tr(context, 'You', 'شما') : groups.memberLabel(member);
    final address = groups.memberCachedAddress(member);
    final radius = BorderRadius.vertical(
      top: isFirst ? const Radius.circular(LoomRadii.surface) : Radius.zero,
      bottom: isLast ? const Radius.circular(LoomRadii.surface) : Radius.zero,
    );
    return Material(
      color: p.surface,
      clipBehavior: Clip.antiAlias,
      borderRadius: radius,
      child: InkWell(
        onTap: self || groups.busy ? null : () => onOpenMember(member),
        child: Column(
          children: [
            Container(
              constraints: const BoxConstraints(minHeight: 64),
              padding: const EdgeInsetsDirectional.only(
                start: 14,
                end: 8,
                top: 8,
                bottom: 8,
              ),
              child: Row(
                children: [
                  LoomAvatar(label: name, size: 42),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                        if (address != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            address,
                            textDirection: TextDirection.ltr,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(color: p.textSecondary),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (member.role != 'member')
                    Container(
                      margin: const EdgeInsetsDirectional.only(end: 4),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: p.primary.withValues(alpha: .10),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        _role(context, member.role),
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: p.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  if (!self)
                    PopupMenuButton<String>(
                      tooltip: tr(context, 'Member options', 'گزینه‌های عضو'),
                      enabled: !groups.busy,
                      onSelected: (value) => value == 'chat'
                          ? onOpenMember(member)
                          : onMemberAction(member, value),
                      itemBuilder: (context) => [
                        PopupMenuItem(
                          value: 'chat',
                          child: Text(
                            tr(context, 'Send message', 'ارسال پیام'),
                          ),
                        ),
                        if (owner && member.role != 'owner')
                          PopupMenuItem(
                            value: member.role == 'admin' ? 'member' : 'admin',
                            child: Text(
                              member.role == 'admin'
                                  ? tr(
                                      context,
                                      'Remove admin role',
                                      'برداشتن نقش مدیر',
                                    )
                                  : tr(context, 'Make admin', 'تبدیل به مدیر'),
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
            ),
            if (showDivider)
              Padding(
                padding: const EdgeInsetsDirectional.only(start: 68),
                child: Divider(height: 1, color: p.border),
              ),
          ],
        ),
      ),
    );
  }
}
