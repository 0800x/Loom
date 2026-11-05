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
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 32),
                    child: Text(
                      tr(
                        context,
                        'Only administrators can review requests.',
                        'فقط مدیرها می‌توانند درخواست‌ها را بررسی کنند.',
                      ),
                      textAlign: TextAlign.center,
                      style: TextStyle(color: context.loom.textSecondary),
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
                        style: TextStyle(color: context.loom.textSecondary),
                      ),
                    ),
                  ),
                if (groups.error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: LoomFeedbackSurface(
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
                  ),
                // One continuous card of requests with flat rows.
                if (requests.isNotEmpty)
                  Material(
                    color: context.loom.surface,
                    clipBehavior: Clip.antiAlias,
                    borderRadius: BorderRadius.circular(LoomRadii.surface),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (var i = 0; i < requests.length; i++)
                          Builder(
                            key: ValueKey(
                              'join-request-$i',
                            ),
                            builder: (context) {
                              final member = LoomGroupMember.fromJson(
                                Map<String, Object?>.from(
                                  requests[i].first['member'] as Map,
                                ),
                              );
                              final pending = requests[i].any(
                                (r) => r['status'] == 'pending',
                              );
                              final working =
                                  _deciding == member.accountId;
                              return Column(
                                children: [
                                  Container(
                                    constraints: const BoxConstraints(
                                      minHeight: 72,
                                    ),
                                    padding: const EdgeInsetsDirectional.only(
                                      start: 14,
                                      end: 10,
                                      top: 10,
                                      bottom: 10,
                                    ),
                                    child: Row(
                                      children: [
                                        LoomAvatar(
                                          label: groups.memberLabel(member),
                                          size: 42,
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            mainAxisAlignment:
                                                MainAxisAlignment.center,
                                            children: [
                                              Text(
                                                groups.memberLabel(member),
                                                maxLines: 1,
                                                overflow:
                                                    TextOverflow.ellipsis,
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .bodyMedium
                                                    ?.copyWith(
                                                      fontWeight:
                                                          FontWeight.w600,
                                                    ),
                                              ),
                                              const SizedBox(height: 2),
                                              Text(
                                                groups.memberCachedAddress(
                                                      member,
                                                    ) ??
                                                    tr(
                                                      context,
                                                      'Wants to join this group',
                                                      'درخواست عضویت در گروه',
                                                    ),
                                                maxLines: 1,
                                                overflow:
                                                    TextOverflow.ellipsis,
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .labelSmall
                                                    ?.copyWith(
                                                      color: context.loom
                                                          .textSecondary,
                                                    ),
                                              ),
                                              if (!pending)
                                                Padding(
                                                  padding:
                                                      const EdgeInsets.only(
                                                        top: 3,
                                                      ),
                                                  child: Text(
                                                    tr(
                                                      context,
                                                      'Accepted. Completing membership…',
                                                      'پذیرفته شد؛ در حال تکمیل عضویت…',
                                                    ),
                                                    style: Theme.of(context)
                                                        .textTheme
                                                        .labelSmall
                                                        ?.copyWith(
                                                          color: context.loom
                                                              .primary,
                                                        ),
                                                  ),
                                                ),
                                            ],
                                          ),
                                        ),
                                        if (working)
                                          const SizedBox.square(
                                            dimension: 18,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                            ),
                                          )
                                        else if (pending) ...[
                                          _RequestButton(
                                            tooltip: tr(
                                              context,
                                              'Decline',
                                              'رد کردن',
                                            ),
                                            icon: LoomIcons.close_rounded,
                                            color: context.loom.critical,
                                            onPressed:
                                                _deciding != null || groups.busy
                                                ? null
                                                : () => _decide(
                                                    groups,
                                                    requests[i],
                                                    false,
                                                  ),
                                          ),
                                          const SizedBox(width: 8),
                                          _RequestButton(
                                            tooltip: tr(
                                              context,
                                              'Approve',
                                              'تأیید',
                                            ),
                                            icon: LoomIcons.check_rounded,
                                            color: context.loom.primary,
                                            onPressed:
                                                _deciding != null || groups.busy
                                                ? null
                                                : () => _decide(
                                                    groups,
                                                    requests[i],
                                                    true,
                                                  ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                  if (i < requests.length - 1)
                                    Padding(
                                      padding:
                                          const EdgeInsetsDirectional.only(
                                            start: 68,
                                          ),
                                      child: Divider(
                                        height: 1,
                                        color: context.loom.border,
                                      ),
                                    ),
                                ],
                              );
                            },
                          ),
                      ],
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

/// Small circular decision button (decline / approve) on a tinted disc.
class _RequestButton extends StatelessWidget {
  const _RequestButton({
    required this.tooltip,
    required this.icon,
    required this.color,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final Color color;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    onPressed: onPressed,
    style: IconButton.styleFrom(
      backgroundColor: color.withValues(alpha: .10),
      foregroundColor: color,
      minimumSize: const Size(38, 38),
      maximumSize: const Size(38, 38),
    ),
    icon: Icon(icon, size: 19),
  );
}
