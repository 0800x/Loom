import 'package:loom_design/loom_design.dart';
import 'package:flutter/material.dart';

import '../../dev/preview_data.dart';

class DesignLabScreen extends StatefulWidget {
  const DesignLabScreen({
    required this.themeMode,
    required this.glassQuality,
    required this.locale,
    required this.onThemeChanged,
    required this.onGlassQualityChanged,
    required this.onLocaleChanged,
    super.key,
  });
  final LoomThemeMode themeMode;
  final LoomGlassQuality glassQuality;
  final Locale locale;
  final ValueChanged<LoomThemeMode> onThemeChanged;
  final ValueChanged<LoomGlassQuality> onGlassQualityChanged;
  final ValueChanged<Locale> onLocaleChanged;

  @override
  State<DesignLabScreen> createState() => _DesignLabScreenState();
}

class _DesignLabScreenState extends State<DesignLabScreen> {
  int nav = 0;
  bool get rtl => widget.locale.languageCode == 'fa';
  bool expanded = false;
  bool reduceMotion = false;
  bool reduceTransparency = false;
  bool highContrast = false;
  bool largeText = false;

  @override
  Widget build(BuildContext context) {
    final p = context.loom;
    final content = Scaffold(
      appBar: LoomGlassAppBar(title: const Text('Design Lab · debug only')),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: expanded ? 1000 : 430),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  DropdownButton<LoomThemeMode>(
                    value: widget.themeMode,
                    items: LoomThemeMode.values
                        .map(
                          (m) =>
                              DropdownMenuItem(value: m, child: Text(m.name)),
                        )
                        .toList(),
                    onChanged: (m) {
                      if (m != null) widget.onThemeChanged(m);
                    },
                  ),
                  DropdownButton<LoomGlassQuality>(
                    value: widget.glassQuality,
                    items: LoomGlassQuality.values
                        .map(
                          (m) => DropdownMenuItem(
                            value: m,
                            child: Text('Glass ${m.name}'),
                          ),
                        )
                        .toList(),
                    onChanged: (m) {
                      if (m != null) widget.onGlassQualityChanged(m);
                    },
                  ),
                  FilterChip(
                    label: const Text('RTL'),
                    selected: rtl,
                    onSelected: (v) => widget.onLocaleChanged(
                      v ? const Locale('fa') : const Locale('en'),
                    ),
                  ),
                  FilterChip(
                    label: const Text('Expanded preview'),
                    selected: expanded,
                    onSelected: (v) => setState(() => expanded = v),
                  ),
                  FilterChip(
                    label: const Text('Reduce Motion'),
                    selected: reduceMotion,
                    onSelected: (v) => setState(() => reduceMotion = v),
                  ),
                  FilterChip(
                    label: const Text('Reduce Transparency'),
                    selected: reduceTransparency,
                    onSelected: (v) => setState(() => reduceTransparency = v),
                  ),
                  FilterChip(
                    label: const Text('High Contrast'),
                    selected: highContrast,
                    onSelected: (v) => setState(() => highContrast = v),
                  ),
                  FilterChip(
                    label: const Text('Large Text'),
                    selected: largeText,
                    onSelected: (v) => setState(() => largeText = v),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const _Title('GlassSurface'),
              const LoomGlassSurface(
                strength: LoomGlassStrength.strong,
                padding: EdgeInsets.all(16),
                child: Text(
                  'Chrome glass uses controlled blur. Rows and message bubbles do not.',
                ),
              ),
              const _Title('Buttons'),
              const Wrap(
                spacing: 8,
                children: [
                  LoomGlassButton(
                    label: 'Secondary',
                    icon: LoomIcons.tune_rounded,
                  ),
                  LoomGlassButton(
                    label: 'Primary',
                    icon: LoomIcons.arrow_forward_rounded,
                    primary: true,
                  ),
                ],
              ),
              const _Title('Navigation'),
              LoomGlassNavigation(
                selectedIndex: nav,
                onSelected: (v) => setState(() => nav = v),
                destinations: const [
                  LoomNavigationDestination(
                    LoomIcons.chat_bubble_outline_rounded,
                    'Chats',
                  ),
                  LoomNavigationDestination(
                    LoomIcons.people_outline_rounded,
                    'People',
                  ),
                  LoomNavigationDestination(LoomIcons.call_outlined, 'Calls'),
                  LoomNavigationDestination(
                    LoomIcons.settings_outlined,
                    'Settings',
                  ),
                ],
              ),
              const _Title('Composer'),
              const LoomGlassComposer(
                hintText: 'Message',
                attachTooltip: 'Attach',
                voiceTooltip: 'Voice message',
                sendTooltip: 'Send',
              ),
              const _Title('Connectivity Pill'),
              const Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  LoomConnectivityPill(
                    state: LoomConnectivity.online,
                    label: 'Online',
                  ),
                  LoomConnectivityPill(
                    state: LoomConnectivity.local,
                    label: 'Local',
                  ),
                  LoomConnectivityPill(
                    state: LoomConnectivity.nearby,
                    label: 'Nearby',
                  ),
                  LoomConnectivityPill(
                    state: LoomConnectivity.queued,
                    label: 'Queued',
                  ),
                  LoomConnectivityPill(
                    state: LoomConnectivity.unavailable,
                    label: 'Node unavailable',
                  ),
                ],
              ),
              const _Title('Avatar + Presence'),
              const Row(
                children: [
                  LoomAvatar(label: 'Sara Rahimi', presence: true),
                  SizedBox(width: 10),
                  LoomAvatar(label: 'Ali Moradi'),
                ],
              ),
              const _Title('Chat Row'),
              LoomChatRow(
                name: LoomPreviewData.conversations.first.name,
                preview: LoomPreviewData.conversations.first.preview,
                time: '09:41',
                unread: 2,
                presence: true,
                pinned: true,
                draftLabel: 'Draft',
                typingLabel: 'typing…',
              ),
              const _Title('Message Bubble'),
              const LoomMessageBubble(
                text: 'Compact content surface without backdrop blur.',
                time: '09:44',
                mine: true,
              ),
              const _Title('Node Row'),
              LoomNodeCard(
                flag: LoomPreviewData.nodes.first.flag,
                name: LoomPreviewData.nodes.first.name,
                location: LoomPreviewData.nodes.first.location,
                latency: LoomPreviewData.nodes.first.latency,
                registration: LoomPreviewData.nodes.first.registration,
                federation: LoomPreviewData.nodes.first.federation,
                capacity: LoomPreviewData.nodes.first.capacity,
                viewLabel: 'View Node',
                registerLabel: 'Register',
              ),
              const _Title('Profile Hero'),
              const LoomProfileHero(
                name: 'Sara Rahimi',
                presence: 'Online · preview',
                address: '@sara:karaj.example',
              ),
              const _Title('Settings Row'),
              const LoomSettingsRow(
                icon: LoomIcons.route_outlined,
                title: 'Connectivity',
                subtitle: 'Home Node, local paths, nearby capability',
              ),
              const _Title('Sheet'),
              const LoomGlassSheet(child: Text('Glass sheet preview')),
              const _Title('Dialog'),
              OutlinedButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (dialogContext) => LoomGlassDialog(
                    title: 'Loom dialog',
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(dialogContext).pop(),
                        child: const Text('Close'),
                      ),
                    ],
                    child: const Text('Deterministic Design Lab dialog.'),
                  ),
                ),
                child: const Text('Open dialog'),
              ),
              const _Title('Context Menu'),
              const Align(
                alignment: AlignmentDirectional.centerStart,
                child: LoomContextMenu(
                  actions: [
                    LoomContextAction(
                      label: 'Reply',
                      icon: LoomIcons.reply_rounded,
                    ),
                    LoomContextAction(
                      label: 'Copy',
                      icon: LoomIcons.copy_rounded,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 30),
              Text(
                'Preview width mode: ${expanded ? 'expanded' : 'compact'}',
                style: Theme.of(context)
                    .textTheme
                    .labelSmall
                    ?.copyWith(color: p.textMuted),
              ),
            ],
          ),
        ),
      ),
    );
    Widget preview = LoomAccessibilityScope(
      overrides: LoomAccessibilityOverrides(
        reduceMotion: reduceMotion,
        reduceTransparency: reduceTransparency,
        highContrast: highContrast,
        largeText: largeText,
      ),
      child: content,
    );
    if (largeText) {
      preview = MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: const TextScaler.linear(1.35)),
        child: preview,
      );
    }
    return Directionality(
      textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
      child: preview,
    );
  }
}

class _Title extends StatelessWidget {
  const _Title(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 22, bottom: 8),
        child: Text(text, style: Theme.of(context).textTheme.titleMedium),
      );
}

