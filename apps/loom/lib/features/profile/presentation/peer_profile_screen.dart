import 'dart:async';

import 'package:loom_design/loom_design.dart';
import 'package:loom_models/loom_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/loom_strings.dart';
import '../../messaging/application/messaging_session_controller.dart';

import 'package:url_launcher/url_launcher.dart';

import '../../calls/presentation/call_surfaces.dart';
import 'profile_common.dart';
import 'profile_header.dart';

class LoomPeerProfileScreen extends StatelessWidget {
  const LoomPeerProfileScreen({
    required this.address,
    required this.displayName,
    this.identityId,
    this.conversationId,
    this.messaging,
    this.mediaBuilder,
    super.key,
  });
  final String address;
  final String displayName;
  final String? identityId;
  final String? conversationId;
  final LoomMessagingSessionController? messaging;
  final Widget Function(LoomVisibleMessage)? mediaBuilder;
  @override
  Widget build(BuildContext context) {
    final p = context.loom;
    final name = displayName.trim().isEmpty ? address : displayName;
    return Scaffold(
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics(),
        ),
        slivers: [
          LoomProfileHeader(name: name, identityId: identityId),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            sliver: SliverList.list(
              children: [
                // Telegram-style quick actions: circular tinted discs with
                // captions, evenly spaced under the hero header.
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Wrap(
                    alignment: WrapAlignment.spaceEvenly,
                    runSpacing: 12,
                    children: [
                      ProfileQuickAction(
                        icon: LoomIcons.chat_bubble_outline_rounded,
                        label: tr(context, 'Message', 'پیام'),
                        onTap: () => Navigator.pop(context),
                      ),
                      ProfileQuickAction(
                        icon: LoomIcons.call_outlined,
                        label: tr(context, 'Audio', 'صوتی'),
                        onTap: () => unawaited(
                          startAddressCallFromUi(
                            context,
                            address,
                            LoomCallKind.audio,
                          ),
                        ),
                      ),
                      ProfileQuickAction(
                        icon: LoomIcons.videocam_outlined,
                        label: tr(context, 'Video', 'ویدیو'),
                        onTap: () => unawaited(
                          startAddressCallFromUi(
                            context,
                            address,
                            LoomCallKind.video,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                ProfileSection(
                  title: tr(context, 'Contact', 'اطلاعات تماس'),
                  children: [
                    ProfileInfoRow(
                      icon: LoomIcons.link_outlined,
                      label: tr(context, 'Loom address', 'نشانی لوم'),
                      value: address,
                      iconColor: p.primary,
                      trailing: IconButton(
                        tooltip: tr(context, 'Copy address', 'کپی نشانی'),
                        onPressed: () => _copyAddress(context),
                        icon: const Icon(LoomIcons.copy_outlined, size: 20),
                      ),
                      onTap: () => _copyAddress(context),
                      showDivider: identityId?.isNotEmpty == true,
                    ),
                    if (identityId?.isNotEmpty == true)
                      ProfileIdentityValue(
                        label: tr(
                          context,
                          'Identity fingerprint',
                          'اثر انگشت هویت',
                        ),
                        value: identityId!,
                        showDivider: false,
                      ),
                  ],
                ),
                if (messaging != null)
                  _BlockContactRow(address: address, messaging: messaging!),
                if (conversationId != null &&
                    messaging != null &&
                    mediaBuilder != null)
                  _SharedConversationMedia(
                    conversationId: conversationId!,
                    messaging: messaging!,
                    mediaBuilder: mediaBuilder!,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _copyAddress(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: address));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr(context, 'Address copied', 'نشانی کپی شد'))),
      );
    }
  }
}

class _SharedConversationMedia extends StatefulWidget {
  const _SharedConversationMedia({
    required this.conversationId,
    required this.messaging,
    required this.mediaBuilder,
  });
  final String conversationId;
  final LoomMessagingSessionController messaging;
  final Widget Function(LoomVisibleMessage) mediaBuilder;
  @override
  State<_SharedConversationMedia> createState() =>
      _SharedConversationMediaState();
}

class _SharedConversationMediaState extends State<_SharedConversationMedia> {
  int _tab = 0;
  static final _links = RegExp(r'https?://[^\s<>]+');
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.messaging,
    builder: (context, _) {
      final messages = widget.messaging
          .visibleMessagesFor(widget.conversationId)
          .where((m) {
            if (!m.readable) return false;
            final attachment = m.content.attachment;
            return switch (_tab) {
              0 =>
                attachment != null &&
                    [
                      'image',
                      'video',
                      'video_note',
                    ].contains(attachment['kind']),
              1 =>
                attachment?['kind'] == 'audio' && attachment?['music'] == true,
              2 =>
                attachment?['kind'] == 'audio' && attachment?['music'] != true,
              _ => _links.hasMatch(m.content.text),
            };
          })
          .toList();
      final labels = [
        tr(context, 'Media', 'مدیا'),
        tr(context, 'Music', 'موسیقی'),
        tr(context, 'Voice', 'صدا'),
        tr(context, 'Links', 'لینک‌ها'),
      ];
      return ProfileSection(
        title: tr(context, 'Shared', 'مشترک‌ها'),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: SizedBox(
              height: 36,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: labels.length,
                separatorBuilder: (_, _) => const SizedBox(width: 6),
                itemBuilder: (_, i) {
                  final selected = _tab == i;
                  return Material(
                    color: selected
                        ? context.loom.primary
                        : context.loom.primary.withValues(alpha: .08),
                    borderRadius: BorderRadius.circular(18),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(18),
                      onTap: () => setState(() => _tab = i),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        child: Center(
                          child: Text(
                            labels[i],
                            style: Theme.of(context).textTheme.labelMedium
                                ?.copyWith(
                                  color: selected
                                      ? Colors.white
                                      : context.loom.textPrimary,
                                  fontWeight: selected
                                      ? FontWeight.w600
                                      : FontWeight.w500,
                                ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (messages.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                tr(
                  context,
                  'No shared items in loaded history',
                  'موردی در تاریخچهٔ بارگذاری‌شده وجود ندارد',
                ),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: context.loom.textSecondary,
                ),
              ),
            )
          else
            SizedBox(
              height: 420,
              child: _tab == 0
                  ? GridView.builder(
                      padding: const EdgeInsets.only(bottom: 12),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            crossAxisSpacing: 2,
                            mainAxisSpacing: 2,
                          ),
                      itemCount: messages.length,
                      itemBuilder: (_, i) => ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: widget.mediaBuilder(messages[i]),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.only(bottom: 12),
                      itemCount: messages.length,
                      separatorBuilder: (_, _) => const Divider(height: 16),
                      itemBuilder: (_, i) => _tab == 3
                          ? Column(
                              children: _links
                                  .allMatches(messages[i].content.text)
                                  .map((match) {
                                    final link = match.group(0)!;
                                    return ListTile(
                                      leading: const Icon(LoomIcons.link),
                                      title: Text(
                                        link,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        textDirection: TextDirection.ltr,
                                      ),
                                      onTap: () async {
                                        try {
                                          await launchUrl(
                                            Uri.parse(link),
                                            mode:
                                                LaunchMode.externalApplication,
                                          );
                                        } catch (_) {}
                                      },
                                    );
                                  })
                                  .toList(),
                            )
                          : widget.mediaBuilder(messages[i]),
                    ),
            ),
        ],
      );
    },
  );
}

/// Block / unblock control. Blocking hides future inbound messages from this
/// address, suppresses notifications and refuses outgoing sends; existing
/// history stays on the device.
class _BlockContactRow extends StatefulWidget {
  const _BlockContactRow({required this.address, required this.messaging});

  final String address;
  final LoomMessagingSessionController messaging;

  @override
  State<_BlockContactRow> createState() => _BlockContactRowState();
}

class _BlockContactRowState extends State<_BlockContactRow> {
  late bool _blocked = widget.messaging.isPeerBlocked(widget.address);
  bool _working = false;

  Future<void> _toggle() async {
    if (_working) return;
    if (!_blocked) {
      final confirmed = await showLoomConfirmDialog(
        context: context,
        title: tr(context, 'Block contact?', 'مسدود کردن مخاطب؟'),
        message: tr(
          context,
          'New messages from this address will not be shown or notified, and you cannot send to them until you unblock.',
          'پیام‌های جدید این نشانی نمایش داده نمی‌شوند و اعلانی نمی‌آید؛ تا زمان رفع مسدودی نمی‌توانید به او پیام دهید.',
        ),
        confirmLabel: tr(context, 'Block', 'مسدود کردن'),
        destructive: true,
      );
      if (!confirmed || !mounted) return;
    }
    setState(() => _working = true);
    try {
      if (_blocked) {
        await widget.messaging.unblockPeer(widget.address);
      } else {
        await widget.messaging.blockPeer(widget.address);
      }
      if (mounted) setState(() => _blocked = !_blocked);
    } catch (_) {
      // The list re-renders from the store; a failure keeps prior state.
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.loom;
    return ProfileSection(
      title: tr(context, 'Privacy', 'حریم خصوصی'),
      children: [
        InkWell(
          onTap: _working ? null : _toggle,
          child: Container(
            constraints: const BoxConstraints(minHeight: 60),
            padding: const EdgeInsetsDirectional.only(
              start: 16,
              end: 16,
              top: 9,
              bottom: 9,
            ),
            child: Row(
              children: [
                SizedBox.square(
                  dimension: 34,
                  child: Icon(
                    _blocked ? LoomIcons.check : LoomIcons.shield_outlined,
                    size: 19,
                    color: _blocked ? p.primary : p.critical,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        _blocked
                            ? tr(context, 'Unblock contact', 'رفع مسدودی مخاطب')
                            : tr(
                                context,
                                'Block contact',
                                'مسدود کردن مخاطب',
                              ),
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: _blocked ? p.primary : p.critical,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _blocked
                            ? tr(
                                context,
                                'Messages from this address are hidden. Unblock to resume.',
                                'پیام‌های این نشانی پنهان است؛ برای ادامه گفتگو رفع مسدودی کنید.',
                              )
                            : tr(
                                context,
                                'Hide future messages and stop notifications.',
                                'پیام‌های بعدی پنهان و اعلان‌ها قطع می‌شود.',
                              ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(color: p.textSecondary),
                      ),
                    ],
                  ),
                ),
                if (_working)
                  const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
