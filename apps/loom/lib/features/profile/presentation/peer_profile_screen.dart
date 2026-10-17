import 'dart:async';

import 'package:loom_design/loom_design.dart';
import 'package:loom_models/loom_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/loom_strings.dart';
import '../../messaging/application/messaging_session_controller.dart';

import 'package:url_launcher/url_launcher.dart';

import '../../calls/presentation/call_surfaces.dart';
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
    final name = displayName.trim().isEmpty ? address : displayName;
    return Scaffold(
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics(),
        ),
        slivers: [
          LoomProfileHeader(name: name, identityId: identityId),
          SliverPadding(
            padding: const EdgeInsets.all(16),
            sliver: SliverList.list(
              children: [
                Row(
                  children: [
                    _PeerAction(
                      icon: LoomIcons.chat_bubble_outline_rounded,
                      label: tr(context, 'Message', 'پیام'),
                      onTap: () => Navigator.pop(context),
                    ),
                    const SizedBox(width: 8),
                    _PeerAction(
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
                    const SizedBox(width: 8),
                    _PeerAction(
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
                const SizedBox(height: 24),
                Card(
                  elevation: 0,
                  color: context.loom.surface,
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 10,
                    ),
                    title: Text(address, textDirection: TextDirection.ltr),
                    subtitle: Text(
                      tr(
                        context,
                        'Loom address · tap to copy',
                        'نشانی لوم · برای کپی بزنید',
                      ),
                    ),
                    trailing: const Icon(LoomIcons.copy_outlined),
                    onTap: () async {
                      await Clipboard.setData(ClipboardData(text: address));
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              tr(context, 'Address copied', 'نشانی کپی شد'),
                            ),
                          ),
                        );
                      }
                    },
                  ),
                ),
                if (identityId?.isNotEmpty == true)
                  Card(
                    elevation: 0,
                    color: context.loom.surface,
                    child: ExpansionTile(
                      leading: const Icon(LoomIcons.shield_outlined),
                      title: Text(
                        tr(context, 'Identity details', 'جزئیات هویت'),
                      ),
                      childrenPadding: const EdgeInsets.all(18),
                      children: [
                        SelectableText(
                          identityId!,
                          textDirection: TextDirection.ltr,
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 32),
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
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 48,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: labels.length,
              separatorBuilder: (_, _) => const SizedBox(width: 6),
              itemBuilder: (_, i) => ChoiceChip(
                label: Text(labels[i]),
                selected: _tab == i,
                onSelected: (_) => setState(() => _tab = i),
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
              ),
            )
          else
            SizedBox(
              height: 420,
              child: _tab == 0
                  ? GridView.builder(
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            crossAxisSpacing: 3,
                            mainAxisSpacing: 3,
                          ),
                      itemCount: messages.length,
                      itemBuilder: (_, i) => ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: widget.mediaBuilder(messages[i]),
                      ),
                    )
                  : ListView.separated(
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

class _PeerAction extends StatelessWidget {
  const _PeerAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Expanded(
    child: Material(
      color: context.loom.surface,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            children: [
              Icon(icon, color: context.loom.primary),
              const SizedBox(height: 8),
              Text(label, style: Theme.of(context).textTheme.labelLarge),
            ],
          ),
        ),
      ),
    ),
  );
}
