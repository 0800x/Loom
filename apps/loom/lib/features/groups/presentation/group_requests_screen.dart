import 'dart:async';

import 'package:loom_design/loom_design.dart';
import 'package:loom_models/loom_models.dart';
import 'package:flutter/material.dart';

import '../../../app/loom_strings.dart';
import '../application/groups_controller.dart';

class LoomGroupRequestsScreen extends StatefulWidget {
  const LoomGroupRequestsScreen({required this.groupId, super.key});
  final String groupId;
  @override
  State<LoomGroupRequestsScreen> createState() =>
      _LoomGroupRequestsScreenState();
}

class _LoomGroupRequestsScreenState extends State<LoomGroupRequestsScreen> {
  final _loaded = <String>{};
  String? _deciding;

  Future<void> _decide(
    LoomGroupsController groups,
    List<Map<String, Object?>> requests,
    bool approve,
  ) async {
    if (_deciding != null || groups.busy || requests.isEmpty) return;
    final first = LoomGroupMember.fromJson(
      Map<String, Object?>.from(requests.first['member'] as Map),
    );
    setState(() => _deciding = first.accountId);
    try {
      for (final request in requests) {
        if (request['status'] != 'pending') continue;
        final member = LoomGroupMember.fromJson(
          Map<String, Object?>.from(request['member'] as Map),
        );
        if (!await groups.decideJoin(
          widget.groupId,
          member.deviceId,
          approve,
        )) {
          break;
        }
        if (!mounted) return;
      }
    } finally {
      if (mounted) setState(() => _deciding = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final groups = LoomGroupsScope.of(context);
    final group = groups.groups
        .where((g) => g.id == widget.groupId)
        .firstOrNull;
    final own = group?.members
        .where((m) => m.deviceId == groups.ownDeviceId)
        .firstOrNull;
    final admin = own != null && own.role != 'member';
    final byAccount = <String, List<Map<String, Object?>>>{};
    final profiles = <LoomGroupMember>[];
    if (admin) {
      for (final request in groups.joinRequests[widget.groupId] ?? []) {
        if (!['pending', 'approved'].contains(request['status'])) continue;
        final member = LoomGroupMember.fromJson(
          Map<String, Object?>.from(request['member'] as Map),
        );
        (byAccount[member.accountId] ??= []).add(request);
        if (_loaded.add(member.deviceId)) profiles.add(member);
      }
    }
    if (profiles.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(groups.loadMemberProfiles(profiles));
      });
    }
    final requests = byAccount.values.toList();
    return Scaffold(
      appBar: LoomGlassAppBar(
        title: Text(tr(context, 'Join requests', 'درخواست‌های عضویت')),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: LoomSizing.detailsMax),
          child: RefreshIndicator(
            onRefresh: () async {
              await groups.synchronize();
            },
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(16),
              children: [
                if (!admin)
                  Text(
                    tr(
                      context,
                      'Only administrators can review requests.',
                      'فقط مدیرها می‌توانند درخواست‌ها را بررسی کنند.',
                    ),
                  )
                else if (requests.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 64),
                    child: Center(
                      child: Text(
                        tr(
                          context,
                          'No pending requests',
                          'درخواستی در انتظار نیست',
                        ),
                      ),
                    ),
                  ),
                if (groups.error != null)
                  LoomFeedbackSurface(
                    message: tr(
                      context,
                      'Unable to complete the request. Refresh and try again.',
                      'درخواست انجام نشد؛ صفحه را تازه‌سازی و دوباره تلاش کنید.',
                    ),
                    actionLabel: tr(context, 'Retry', 'تلاش مجدد'),
                    onAction: groups.busy
                        ? null
                        : () => unawaited(groups.synchronize()),
                  ),
                for (final accountRequests in requests)
                  Builder(
                    builder: (context) {
                      final member = LoomGroupMember.fromJson(
                        Map<String, Object?>.from(
                          accountRequests.first['member'] as Map,
                        ),
                      );
                      final pending = accountRequests.any(
                        (r) => r['status'] == 'pending',
                      );
                      final working = _deciding == member.accountId;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: LoomGlassSurface(
                          radius: 20,
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              ListTile(
                                contentPadding: EdgeInsets.zero,
                                leading: LoomAvatar(
                                  label: groups.memberLabel(member),
                                  size: 44,
                                ),
                                title: Text(
                                  groups.memberLabel(member),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text(
                                  groups.memberCachedAddress(member) ??
                                      tr(
                                        context,
                                        'Wants to join this group',
                                        'درخواست عضویت در گروه',
                                      ),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (working) const LinearProgressIndicator(),
                              if (pending)
                                Wrap(
                                  alignment: WrapAlignment.end,
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: [
                                    TextButton(
                                      onPressed:
                                          _deciding != null || groups.busy
                                          ? null
                                          : () => _decide(
                                              groups,
                                              accountRequests,
                                              false,
                                            ),
                                      child: Text(
                                        tr(context, 'Decline', 'رد کردن'),
                                      ),
                                    ),
                                    FilledButton(
                                      onPressed:
                                          _deciding != null || groups.busy
                                          ? null
                                          : () => _decide(
                                              groups,
                                              accountRequests,
                                              true,
                                            ),
                                      child: Text(
                                        tr(context, 'Approve', 'تأیید'),
                                      ),
                                    ),
                                  ],
                                )
                              else
                                Text(
                                  tr(
                                    context,
                                    'Accepted. Completing membership…',
                                    'پذیرفته شد؛ در حال تکمیل عضویت…',
                                  ),
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
