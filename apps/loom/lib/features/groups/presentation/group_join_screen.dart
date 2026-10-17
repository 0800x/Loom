import 'dart:async';

import 'package:loom_models/loom_models.dart';
import 'package:loom_design/loom_design.dart';
import 'package:flutter/material.dart';

import '../../../app/loom_strings.dart';
import '../application/groups_controller.dart';

class LoomGroupJoinScreen extends StatefulWidget {
  const LoomGroupJoinScreen({this.initialLink, super.key});
  final String? initialLink;
  @override
  State<LoomGroupJoinScreen> createState() => _LoomGroupJoinScreenState();
}

class _LoomGroupJoinScreenState extends State<LoomGroupJoinScreen> {
  late final _input = TextEditingController(text: widget.initialLink);
  LoomGroupInviteLink? _link;
  Map<String, Object?>? _preview;
  String? _error;
  bool _loading = false, _checking = false;
  Timer? _poll;
  @override
  void initState() {
    super.initState();
    if (widget.initialLink != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    _input.dispose();
    super.dispose();
  }

  void _stopPolling() {
    _poll?.cancel();
    _poll = null;
  }

  String _failure(LoomGroupsController groups) =>
      groups.errorCode == 'group_invite_unavailable'
      ? tr(
          context,
          'This invitation has expired, was revoked, or is unavailable. Ask an administrator for a new link.',
          'این دعوت منقضی یا لغو شده، یا در دسترس نیست. از مدیر گروه لینک تازه بخواهید.',
        )
      : tr(
          context,
          'The invitation could not be loaded. Check your connection and try again.',
          'دعوت بارگذاری نشد. اتصال را بررسی و دوباره تلاش کنید.',
        );

  Future<void> _load({bool silent = false}) async {
    if (_loading || !mounted) return;
    final groups = LoomGroupsScope.of(context);
    final link = LoomGroupInviteLink.tryParse(_input.text);
    final endpoint = groups.onboarding.nodes.selectedEndpoint;
    if (link == null ||
        endpoint == null ||
        link.node.origin != endpoint.origin) {
      _stopPolling();
      _link = null;
      _preview = null;
      setState(
        () => _error = tr(
          context,
          link == null
              ? 'This invitation link is malformed. Ask an administrator for the complete link.'
              : 'Use an invitation from your current Home Node.',
          link == null
              ? 'لینک دعوت معتبر نیست. لینک کامل را از مدیر گروه بخواهید.'
              : 'لینک دعوت باید متعلق به سرور فعلی حساب شما باشد.',
        ),
      );
      return;
    }
    setState(() {
      if (!silent) _loading = true;
      _error = null;
    });
    final source = _input.text;
    final preview = await groups.previewInvite(link.token);
    if (!mounted || source != _input.text) return;
    setState(() {
      _loading = false;
      _link = link;
      _preview = preview;
      _error = preview == null ? _failure(groups) : null;
    });
    if (preview != null &&
        ['pending', 'approved'].contains(preview['status'])) {
      _poll ??= Timer.periodic(
        const Duration(seconds: 5),
        (_) => _checkJoined(preview['groupId'] as String),
      );
    } else {
      _stopPolling();
    }
  }

  Future<void> _join() async {
    final link = _link;
    if (link == null || _loading || _checking) return;
    final groups = LoomGroupsScope.of(context);
    setState(() => _loading = true);
    final id = await groups.joinInvite(link.token);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _error = id == null ? _failure(groups) : null;
    });
    if (id == null) return;
    await _load();
    if (!mounted) return;
    if (groups.groups.any((g) => g.id == id)) {
      _open(id);
    } else {
      _stopPolling();
      _poll = Timer.periodic(
        const Duration(seconds: 5),
        (_) => _checkJoined(id),
      );
    }
  }

  Future<void> _checkJoined(String id) async {
    if (_loading ||
        _checking ||
        !mounted ||
        ModalRoute.of(context)?.isCurrent != true ||
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      return;
    }
    final groups = LoomGroupsScope.of(context);
    if (groups.busy) return;
    _checking = true;
    try {
      await groups.synchronize();
      if (!mounted) return;
      if (groups.groups.any((g) => g.id == id)) {
        _open(id);
        return;
      }
      await _load(silent: true);
    } finally {
      _checking = false;
    }
  }

  void _open(String id) {
    _stopPolling();
    Navigator.of(context).pushReplacementNamed('/messenger', arguments: id);
  }

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    final waiting = ['pending', 'approved'].contains(preview?['status']);
    final fixedLink = widget.initialLink != null;
    return Scaffold(
      appBar: LoomGlassAppBar(
        title: Text(tr(context, 'Group invitation', 'دعوت به گروه')),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: LoomSizing.formMax),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(24),
            children: [
              if (!fixedLink)
                TextField(
                  controller: _input,
                  enabled: !_loading && !waiting,
                  onChanged: (_) {
                    _stopPolling();
                    setState(() {
                      _link = null;
                      _preview = null;
                      _error = null;
                    });
                  },
                  textDirection: TextDirection.ltr,
                  autocorrect: false,
                  textInputAction: TextInputAction.go,
                  onSubmitted: (_) => _load(),
                  decoration: InputDecoration(
                    labelText: tr(context, 'Invitation link', 'لینک دعوت'),
                  ),
                ),
              const SizedBox(height: 12),
              if (!fixedLink)
                OutlinedButton(
                  onPressed: _loading ? null : _load,
                  child: Text(tr(context, 'Preview group', 'نمایش گروه')),
                ),
              if (_loading) const LinearProgressIndicator(),
              if (_error != null) LoomFeedbackSurface(message: _error!),
              if (_error != null && fixedLink)
                OutlinedButton(
                  onPressed: _loading ? null : _load,
                  child: Text(tr(context, 'Try again', 'تلاش دوباره')),
                ),
              if (preview != null) ...[
                const SizedBox(height: 24),
                Center(
                  child: LoomAvatar(
                    label: preview['title'] as String,
                    size: 96,
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  preview['title'] as String,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                Text(
                  '${preview['memberCount']} ${tr(context, 'members', 'عضو')}',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  _link!.node.authority,
                  textAlign: TextAlign.center,
                  textDirection: TextDirection.ltr,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                Text(
                  tr(
                    context,
                    'Members can see your profile and message you. New members cannot read earlier messages.',
                    'اعضا می‌توانند پروفایل شما را ببینند و پیام خصوصی بدهند. اعضای جدید به پیام‌های قبلی دسترسی ندارند.',
                  ),
                ),
                const SizedBox(height: 16),
                if (waiting)
                  LoomFeedbackSurface(
                    error: false,
                    message: preview['status'] == 'pending'
                        ? tr(
                            context,
                            'Waiting for administrator approval.',
                            'در انتظار تأیید مدیر.',
                          )
                        : tr(
                            context,
                            'Accepted. Waiting for an administrator device to sync the encrypted invitation.',
                            'درخواست پذیرفته شد؛ منتظر همگام‌سازی دستگاه مدیر برای تکمیل عضویت هستیم.',
                          ),
                  ),
                if (preview['status'] == 'removed')
                  LoomFeedbackSurface(
                    message: tr(
                      context,
                      'This device was removed. Rejoining requires a newly authorized device.',
                      'این دستگاه از گروه حذف شده؛ عضویت مجدد به دستگاه تازهٔ مجاز نیاز دارد.',
                    ),
                  ),
                if (preview['status'] == 'rejected')
                  LoomFeedbackSurface(
                    message: tr(
                      context,
                      'The administrator declined this request.',
                      'مدیر درخواست شما را رد کرد.',
                    ),
                  ),
                FilledButton(
                  onPressed:
                      _loading ||
                          waiting ||
                          ['rejected', 'removed'].contains(preview['status'])
                      ? null
                      : preview['status'] == 'joined'
                      ? () => _open(preview['groupId'] as String)
                      : _join,
                  child: Text(
                    preview['status'] == 'joined'
                        ? tr(context, 'Open group', 'باز کردن گروه')
                        : preview['mode'] == 'approval'
                        ? tr(context, 'Request to join', 'درخواست عضویت')
                        : tr(context, 'Join group', 'عضویت در گروه'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
