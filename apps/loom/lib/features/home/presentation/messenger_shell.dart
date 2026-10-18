import '../../messaging/presentation/location_status.dart';
import '../../messaging/presentation/map_launcher.dart';
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:camera/camera.dart';

import 'package:video_compress/video_compress.dart';

import 'package:loom_crypto_bridge/loom_crypto_bridge.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_selector/file_selector.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';
import 'package:record/record.dart';
import 'package:photo_manager/photo_manager.dart' hide LatLng;

import '../../media/application/voice_draft_controller.dart';
import '../../media/application/video_note_geometry.dart';
import '../../media/application/video_note_camera_selection.dart';
import '../../media/application/media_capabilities.dart';
import '../../media/application/media_batch_controller.dart';
import '../../media/presentation/playback_host.dart';
import '../../media/presentation/hold_record_action.dart';
import '../../media/application/playback_controller.dart';
import '../../media/presentation/camera_screen.dart';
import '../../media/presentation/circular_video_preview.dart';

import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../messaging/application/encrypted_media.dart';
import '../../messaging/application/media_preparation.dart';

import 'package:loom_design/loom_design.dart';
import 'package:loom_models/loom_models.dart' as models;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/loom_strings.dart';
import '../../../app/chat_wallpaper.dart';
import '../../settings/presentation/chat_wallpaper_editor.dart';
import 'swipe_navigation.dart';
import '../../../dev/preview_data.dart';
import '../../calls/presentation/call_surfaces.dart';
import '../../calls/application/call_session_controller.dart';
import '../../calls/presentation/calls_screen.dart';
import '../../chat_folders/application/chat_folder_controller.dart';
import '../../chat_folders/presentation/chat_folder_labels.dart';
import '../../messaging/application/messaging_session_controller.dart';
import '../../onboarding/application/logout_service.dart';
import '../../onboarding/application/onboarding_controller.dart';
import '../../people/presentation/people_screen.dart';
import '../../profile/presentation/peer_profile_screen.dart';
import '../../profile/presentation/own_avatar.dart';

import 'create_dial.dart';
import '../../groups/presentation/groups_screen.dart';
import '../../groups/presentation/group_avatar.dart';
import '../../groups/presentation/group_call_screen.dart';
import '../../groups/application/group_call_controller.dart';
import '../../groups/presentation/group_attachment.dart';
import '../../groups/presentation/group_join_screen.dart';

part 'conversation_pane.dart';
part 'conversation_chrome.dart';
part 'settings_search.dart';
part 'conversation_actions.dart';
part 'sync_title.dart';
part 'conversation_media.dart';
part 'conversation_viewer.dart';
part 'conversation_voice.dart';
part 'conversation_recording.dart';
part 'conversation_gallery.dart';
part 'conversation_gallery_preview.dart';
part 'conversation_shared_media.dart';

/// The production Loom shell.
///
/// The visual structure intentionally follows the original Liquid Glass
/// messenger while production data comes from [LoomMessagingSessionController].
/// Preview fixtures are only reachable from debug/design-lab usage.
Future<void> showLoomGroupMedia(
  BuildContext context,
  Uint8List bytes, {
  required bool video,
}) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => _MediaViewer(bytes: bytes, video: video),
  ),
);

class LoomConversationSurface extends StatefulWidget {
  const LoomConversationSurface({
    required this.conversationId,
    this.onBack,
    super.key,
  });
  final String conversationId;
  final VoidCallback? onBack;
  @override
  State<LoomConversationSurface> createState() =>
      _LoomConversationSurfaceState();
}

class _LoomConversationSurfaceState extends State<LoomConversationSurface> {
  final drafts = _ConversationDrafts();
  @override
  void dispose() {
    drafts.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final messaging = LoomMessagingSessionScope.of(context);
    return _ConversationPane(
      preview: false,
      messaging: messaging,
      conversation: messaging.conversations
          .where((c) => c.id == widget.conversationId)
          .firstOrNull,
      drafts: drafts,
      onBack: widget.onBack,
    );
  }
}

class MessengerShell extends StatefulWidget {
  const MessengerShell({this.preview = false, super.key});

  final bool preview;

  @override
  State<MessengerShell> createState() => _MessengerShellState();
}

class _MessengerShellState extends State<MessengerShell> {
  int selected = 0;
  bool compactConversationVisible = false;
  bool detailsVisible = true;
  double _listWidth = 320;
  bool _opened = false;
  String? _selectedConversationId;
  final _drafts = _ConversationDrafts();

  @override
  void dispose() {
    _drafts.dispose();
    super.dispose();
  }

  bool get _previewEnabled => widget.preview && kDebugMode;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_previewEnabled || _opened) {
      return;
    }
    final messaging = LoomMessagingSessionScope.maybeOf(context);
    if (messaging == null) {
      return;
    }
    _opened = true;
    final argument = ModalRoute.of(context)?.settings.arguments;
    if (argument is String && argument.isNotEmpty) {
      _selectedConversationId = argument;
      compactConversationVisible = true;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      unawaited(messaging.open());
    });
  }

  void _selectDestination(int value) {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      selected = value;
      compactConversationVisible = false;
    });
  }

  void _openConversation(String conversationId) {
    setState(() {
      selected = 0;
      _selectedConversationId = conversationId;
      compactConversationVisible = true;
    });
  }

  Future<void> _newChat() async {
    final conversationId = await Navigator.push<String>(
      context,
      MaterialPageRoute<String>(
        builder: (_) => const LoomPeopleScreen(selectForChat: true),
      ),
    );
    if (!mounted || conversationId == null || conversationId.isEmpty) {
      return;
    }
    _openConversation(conversationId);
  }

  models.LoomConversation? _selectedConversation(
    LoomMessagingSessionController? messaging,
  ) {
    if (messaging == null || messaging.conversations.isEmpty) {
      return null;
    }
    final selectedId = _selectedConversationId;
    if (selectedId != null) {
      for (final conversation in messaging.conversations) {
        if (conversation.id == selectedId) {
          return conversation;
        }
      }
    }
    return messaging.conversations.firstOrNull;
  }

  @override
  Widget build(BuildContext context) {
    final preview = _previewEnabled;
    final messaging = preview
        ? null
        : LoomMessagingSessionScope.maybeOf(context);
    final conversation = _selectedConversation(messaging);
    final selectedConversationId = conversation?.id;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyN, control: true): () =>
            unawaited(_newChat()),
        const SingleActivator(LogicalKeyboardKey.digit1, control: true): () =>
            _selectDestination(0),
        const SingleActivator(LogicalKeyboardKey.digit2, control: true): () =>
            _selectDestination(1),
        const SingleActivator(LogicalKeyboardKey.digit3, control: true): () =>
            _selectDestination(2),
        const SingleActivator(LogicalKeyboardKey.digit4, control: true): () =>
            _selectDestination(3),
      },
      child: LoomResponsive(
        compact: (_) => _CompactLayout(
          preview: preview,
          drafts: _drafts,
          messaging: messaging,
          selected: selected,
          selectedConversationId: selectedConversationId,
          selectedConversation: conversation,
          showConversation: compactConversationVisible,
          onSelected: _selectDestination,
          onOpenConversation: _openConversation,
          onCloseConversation: () =>
              setState(() => compactConversationVisible = false),
          onNewChat: _newChat,
        ),
        medium: (_) => _CompactLayout(
          preview: preview,
          drafts: _drafts,
          messaging: messaging,
          selected: selected,
          selectedConversationId: selectedConversationId,
          selectedConversation: conversation,
          showConversation: compactConversationVisible,
          onSelected: _selectDestination,
          onOpenConversation: _openConversation,
          onCloseConversation: () =>
              setState(() => compactConversationVisible = false),
          onNewChat: _newChat,
        ),
        expanded: (_) => _WideLayout(
          listWidth: _listWidth,
          onResizeList: (delta) =>
              setState(() => _listWidth = (_listWidth + delta).clamp(260, 420)),
          preview: preview,
          drafts: _drafts,
          messaging: messaging,
          selected: selected,
          selectedConversationId: selectedConversationId,
          selectedConversation: conversation,
          onSelected: _selectDestination,
          onOpenConversation: _openConversation,
          onNewChat: _newChat,
          showDetails: false,
        ),
        ultraWide: (_) => _WideLayout(
          listWidth: _listWidth,
          onResizeList: (delta) =>
              setState(() => _listWidth = (_listWidth + delta).clamp(260, 420)),
          preview: preview,
          drafts: _drafts,
          messaging: messaging,
          selected: selected,
          selectedConversationId: selectedConversationId,
          selectedConversation: conversation,
          onSelected: _selectDestination,
          onOpenConversation: _openConversation,
          onNewChat: _newChat,
          showDetails: detailsVisible,
          onToggleDetails: () =>
              setState(() => detailsVisible = !detailsVisible),
        ),
      ),
    );
  }
}

class _CompactLayout extends StatefulWidget {
  const _CompactLayout({
    required this.preview,
    required this.drafts,
    required this.messaging,
    required this.selected,
    required this.selectedConversationId,
    required this.selectedConversation,
    required this.showConversation,
    required this.onSelected,
    required this.onOpenConversation,
    required this.onCloseConversation,
    required this.onNewChat,
  });

  final bool preview;
  final _ConversationDrafts drafts;
  final LoomMessagingSessionController? messaging;
  final int selected;
  final String? selectedConversationId;
  final models.LoomConversation? selectedConversation;
  final bool showConversation;
  final ValueChanged<int> onSelected;
  final ValueChanged<String> onOpenConversation;
  final VoidCallback onCloseConversation;
  final VoidCallback onNewChat;

  @override
  State<_CompactLayout> createState() => _CompactLayoutState();
}

class _CompactLayoutState extends State<_CompactLayout>
    with SingleTickerProviderStateMixin {
  late final AnimationController _destinationAnimation;
  final _visited = <int>{};
  final _conversationStackKey = GlobalKey();
  final _conversationOrigins = <String, Rect>{};
  double _tabDirection = 1;

  @override
  void initState() {
    super.initState();
    _visited.add(widget.selected);
    _destinationAnimation = AnimationController(
      vsync: this,
      duration: LoomMotion.component,
      value: 1,
    );
  }

  @override
  void didUpdateWidget(covariant _CompactLayout oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selected != widget.selected) {
      _visited.add(widget.selected);
      _tabDirection = widget.selected > oldWidget.selected ? 1 : -1;
      if (LoomAccessibility.fromContext(context).reduceMotion) {
        _destinationAnimation.value = 1;
      } else {
        _destinationAnimation.forward(from: 0);
      }
    }
  }

  @override
  void dispose() {
    _destinationAnimation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      _ChatList(
        preview: widget.preview,
        messaging: widget.messaging,
        selectedConversationId: widget.selectedConversationId,
        onConversationSelected: widget.onOpenConversation,
        onConversationOrigin: (id, origin) {
          if (origin == null) return;
          _conversationOrigins[id] = origin;
          if (_conversationOrigins.length > 32) {
            _conversationOrigins.remove(_conversationOrigins.keys.first);
          }
        },
        onNewChat: widget.onNewChat,
        onNextSection: () => widget.onSelected(1),
        active: widget.selected == 0 && !widget.showConversation,
      ),
      LoomPeopleScreen(
        embedded: true,
        onConversationSelected: widget.onOpenConversation,
      ),
      LoomCallsScreen(preview: widget.preview),
      _SettingsPane(messaging: widget.messaging),
    ];
    final showConversation = widget.selected == 0 && widget.showConversation;
    final reduceMotion = LoomAccessibility.fromContext(context).reduceMotion;
    return PopScope<void>(
      canPop: !showConversation,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && showConversation) {
          FocusManager.instance.primaryFocus?.unfocus();
          widget.onCloseConversation();
        }
      },
      child: Scaffold(
        body: SafeArea(
          top: false,
          bottom: false,
          child: Stack(
            key: _conversationStackKey,
            children: [
              Positioned.fill(
                child: Offstage(
                  offstage: showConversation,
                  child: SafeArea(
                    child: TickerMode(
                      enabled: !showConversation,
                      child: FadeTransition(
                        opacity: _destinationAnimation.drive(
                          CurveTween(curve: LoomMotion.standard),
                        ),
                        child: SlideTransition(
                          position: _destinationAnimation.drive(
                            Tween<Offset>(
                              begin: Offset(
                                Directionality.of(context) == TextDirection.rtl
                                    ? -.025 * _tabDirection
                                    : .025 * _tabDirection,
                                0,
                              ),
                              end: Offset.zero,
                            ).chain(CurveTween(curve: LoomMotion.standard)),
                          ),
                          child: LoomSectionSwipe(
                            enabled: widget.selected != 0,
                            onPrevious: widget.selected > 0
                                ? () => widget.onSelected(widget.selected - 1)
                                : null,
                            onNext: widget.selected < 3
                                ? () => widget.onSelected(widget.selected + 1)
                                : null,
                            child: IndexedStack(
                              index: widget.selected,
                              children: [
                                for (var i = 0; i < pages.length; i++)
                                  _visited.contains(i)
                                      ? ExcludeFocus(
                                          excluding:
                                              showConversation ||
                                              i != widget.selected,
                                          child: TickerMode(
                                            enabled:
                                                !showConversation &&
                                                i == widget.selected,
                                            child: pages[i],
                                          ),
                                        )
                                      : const SizedBox.shrink(),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Positioned.fill(
                // Outgoing chat chrome remains painted during the fade. It
                // must stop intercepting taps and focus as soon as Back wins.
                child: IgnorePointer(
                  ignoring: !showConversation,
                  child: ExcludeFocus(
                    excluding: !showConversation,
                    child: ExcludeSemantics(
                      excluding: !showConversation,
                      child: AnimatedSwitcher(
                        duration: reduceMotion
                            ? Duration.zero
                            : LoomMotion.route,
                        switchInCurve: Curves.linear,
                        switchOutCurve: Curves.linear,
                        transitionBuilder: (child, animation) {
                          if (child is SizedBox) return child;
                          return LayoutBuilder(
                            builder: (context, constraints) {
                              final destination =
                                  Offset.zero & constraints.biggest;
                              final key = child.key;
                              final global = key is ValueKey<String?>
                                  ? _conversationOrigins[key.value ?? 'preview']
                                  : null;
                              final stack = _conversationStackKey.currentContext
                                  ?.findRenderObject();
                              final source =
                                  global != null && stack is RenderBox
                                  ? stack.globalToLocal(global.topLeft) &
                                        global.size
                                  : destination;
                              return Stack(
                                fit: StackFit.expand,
                                children: [
                                  LoomContainerTransform(
                                    animation: animation,
                                    origin: source,
                                    destination: destination,
                                    radius: 0,
                                    child: TickerMode(
                                      enabled:
                                          showConversation &&
                                          child.key ==
                                              ValueKey(
                                                widget.selectedConversationId,
                                              ),
                                      child: child,
                                    ),
                                  ),
                                ],
                              );
                            },
                          );
                        },
                        child: showConversation
                            ? _ConversationPane(
                                key: ValueKey(widget.selectedConversationId),
                                preview: widget.preview,
                                drafts: widget.drafts,
                                messaging: widget.messaging,
                                conversation: widget.selectedConversation,
                                onBack: widget.onCloseConversation,
                              )
                            : const SizedBox.shrink(),
                      ),
                    ),
                  ),
                ),
              ),
              if (!showConversation)
                PositionedDirectional(
                  start: LoomSpacing.sm,
                  end: LoomSpacing.sm,
                  bottom: LoomSpacing.xs + MediaQuery.paddingOf(context).bottom,
                  child: _BottomNavigation(
                    selected: widget.selected,
                    onSelected: widget.onSelected,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WideLayout extends StatelessWidget {
  const _WideLayout({
    required this.preview,
    required this.drafts,
    required this.messaging,
    required this.selected,
    required this.selectedConversationId,
    required this.selectedConversation,
    required this.onSelected,
    required this.onOpenConversation,
    required this.onNewChat,
    required this.showDetails,
    this.onToggleDetails,
    this.listWidth = 320,
    this.onResizeList,
  });

  final bool preview;
  final _ConversationDrafts drafts;
  final LoomMessagingSessionController? messaging;
  final int selected;
  final String? selectedConversationId;
  final models.LoomConversation? selectedConversation;
  final ValueChanged<int> onSelected;
  final ValueChanged<String> onOpenConversation;
  final VoidCallback onNewChat;
  final bool showDetails;
  final VoidCallback? onToggleDetails;
  final double listWidth;
  final ValueChanged<double>? onResizeList;

  @override
  Widget build(BuildContext context) {
    final palette = context.loom;
    return Scaffold(
      body: SafeArea(
        child: Row(
          children: [
            Container(
              width: 88,
              color: palette.surface,
              padding: const EdgeInsets.symmetric(
                horizontal: LoomSpacing.xs,
                vertical: LoomSpacing.md,
              ),
              child: _DesktopNavigation(
                selected: selected,
                onSelected: onSelected,
              ),
            ),
            VerticalDivider(width: 1, color: palette.border),
            if (selected == 0) ...[
              SizedBox(
                width: listWidth.clamp(
                  260,
                  MediaQuery.sizeOf(context).width * .36,
                ),
                child: _ChatList(
                  preview: preview,
                  messaging: messaging,
                  selectedConversationId: selectedConversationId,
                  onConversationSelected: onOpenConversation,
                  onNewChat: onNewChat,
                ),
              ),
              MouseRegion(
                cursor: SystemMouseCursors.resizeColumn,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onHorizontalDragUpdate: (event) => onResizeList?.call(
                    event.delta.dx *
                        (Directionality.of(context) == TextDirection.rtl
                            ? -1
                            : 1),
                  ),
                  child: SizedBox(
                    width: 8,
                    child: VerticalDivider(
                      width: 8,
                      thickness: 1,
                      color: palette.border,
                    ),
                  ),
                ),
              ),
              Expanded(
                child: _ConversationPane(
                  preview: preview,
                  drafts: drafts,
                  messaging: messaging,
                  conversation: selectedConversation,
                  onToggleDetails: onToggleDetails,
                ),
              ),
              if (showDetails && MediaQuery.sizeOf(context).width >= 1320) ...[
                VerticalDivider(width: 1, color: palette.border),
                SizedBox(
                  width: 320,
                  child: _DetailsPane(
                    preview: preview,
                    messaging: messaging,
                    conversation: selectedConversation,
                  ),
                ),
              ],
            ] else
              Expanded(child: _destination(selected, preview, messaging)),
          ],
        ),
      ),
    );
  }

  Widget _destination(
    int index,
    bool preview,
    LoomMessagingSessionController? messaging,
  ) => switch (index) {
    1 => LoomPeopleScreen(
      embedded: true,
      onConversationSelected: onOpenConversation,
    ),
    2 => LoomCallsScreen(preview: preview),
    3 => _SettingsPane(messaging: messaging),
    _ => const SizedBox.shrink(),
  };
}

class _BottomNavigation extends StatelessWidget {
  const _BottomNavigation({required this.selected, required this.onSelected});

  final int selected;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final strings = LoomStrings.of(context);
    return LoomGlassNavigation(
      selectedIndex: selected,
      onSelected: onSelected,
      destinations: [
        LoomNavigationDestination(LoomIcons.chat_bubble_rounded, strings.chats),
        LoomNavigationDestination(
          LoomIcons.person_outline_rounded,
          strings.people,
        ),
        LoomNavigationDestination(LoomIcons.call_outlined, strings.calls),
        LoomNavigationDestination(
          LoomIcons.settings_outlined,
          strings.settings,
        ),
      ],
    );
  }
}

class _DesktopNavigation extends StatelessWidget {
  const _DesktopNavigation({required this.selected, required this.onSelected});

  final int selected;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final strings = LoomStrings.of(context);
    final items = [
      (LoomIcons.chat_bubble_rounded, strings.chats),
      (LoomIcons.person_outline_rounded, strings.people),
      (LoomIcons.call_outlined, strings.calls),
      (LoomIcons.settings_outlined, strings.settings),
    ];
    return Column(
      children: [
        const LoomRouteMark(size: 42),
        const SizedBox(height: LoomSpacing.lg),
        for (var index = 0; index < items.length; index++) ...[
          _DesktopDestination(
            icon: items[index].$1,
            label: items[index].$2,
            selected: selected == index,
            onTap: () => onSelected(index),
          ),
          if (index == 2) const Spacer(),
        ],
      ],
    );
  }
}

class _DesktopDestination extends StatelessWidget {
  const _DesktopDestination({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.loom;
    return Padding(
      padding: const EdgeInsets.only(bottom: LoomSpacing.xs),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(LoomRadii.surface),
        child: AnimatedContainer(
          duration: LoomAccessibility.fromContext(context).reduceMotion
              ? Duration.zero
              : LoomMotion.component,
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: LoomSpacing.sm),
          decoration: BoxDecoration(
            color: selected
                ? palette.primary.withAlphaFraction(.13)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(LoomRadii.surface),
          ),
          child: Column(
            children: [
              Icon(
                icon,
                color: selected ? palette.primary : palette.textSecondary,
              ),
              const SizedBox(height: 5),
              Text(
                label,
                maxLines: 1,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: selected ? palette.primary : palette.textSecondary,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

const List<LoomChatFolderDefinition> _fallbackChatFolders = [
  LoomChatFolderDefinition(id: loomAllChatsFolderId, name: 'All Chats'),
];

class _ChatList extends StatefulWidget {
  const _ChatList({
    this.onConversationOrigin,
    this.onNextSection,
    this.active = true,
    required this.preview,
    required this.messaging,
    required this.selectedConversationId,
    required this.onConversationSelected,
    required this.onNewChat,
  });

  final bool preview;
  final LoomMessagingSessionController? messaging;
  final String? selectedConversationId;
  final ValueChanged<String> onConversationSelected;
  final void Function(String, Rect?)? onConversationOrigin;
  final VoidCallback onNewChat;
  final VoidCallback? onNextSection;
  final bool active;

  @override
  State<_ChatList> createState() => _ChatListState();
}

class _ChatListState extends State<_ChatList> {
  final search = TextEditingController();
  final _searchSurfaceKey = GlobalKey();
  Rect? _searchOrigin;
  bool _searching = false;
  bool _showArchived = false;
  late final PageController _folderPageController;
  String _selectedFolderId = loomAllChatsFolderId;
  bool _openedFolders = false;

  @override
  void initState() {
    super.initState();
    _folderPageController = PageController();
  }

  @override
  void didUpdateWidget(covariant _ChatList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.active && oldWidget.active) {
      FocusManager.instance.primaryFocus?.unfocus();
    }
  }

  void _closeSearch() {
    setState(() {
      _searching = false;
      search.clear();
    });
    FocusManager.instance.primaryFocus?.unfocus();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (widget.preview || _openedFolders) {
      return;
    }
    final folders = LoomChatFoldersScope.maybeOf(context);
    if (folders == null) {
      return;
    }
    _openedFolders = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(folders.open());
      }
    });
  }

  @override
  void dispose() {
    search.dispose();
    _folderPageController.dispose();
    super.dispose();
  }

  List<LoomChatFolderDefinition> _folders(
    LoomChatFolderController? controller,
  ) => controller?.folders ?? _fallbackChatFolders;

  int _selectedIndex(List<LoomChatFolderDefinition> folders) {
    final index = folders.indexWhere(
      (folder) => folder.id == _selectedFolderId,
    );
    if (index >= 0) {
      return index;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && folders.isNotEmpty) {
        setState(() => _selectedFolderId = folders.first.id);
      }
    });
    return 0;
  }

  void _syncPageController(int index) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !_folderPageController.hasClients ||
          _folderPageController.position.isScrollingNotifier.value) {
        return;
      }
      final current = _folderPageController.page?.round() ?? 0;
      if (current != index) {
        _folderPageController.jumpToPage(index);
      }
    });
  }

  void _selectFolder(List<LoomChatFolderDefinition> folders, int index) {
    if (index < 0 || index >= folders.length) {
      return;
    }
    setState(() => _selectedFolderId = folders[index].id);
    if (_folderPageController.hasClients) {
      if (LoomAccessibility.fromContext(context).reduceMotion) {
        _folderPageController.jumpToPage(index);
        return;
      }
      _folderPageController.animateToPage(
        index,
        duration: LoomMotion.component,
        curve: LoomMotion.emphasized,
      );
    }
  }

  List<models.LoomConversation> _filteredConversations(
    LoomChatFolderDefinition folder,
  ) {
    Iterable<models.LoomConversation> result =
        widget.messaging?.conversations ?? const <models.LoomConversation>[];
    result = result.where(folder.matches);
    result = result.where(
      (item) =>
          (widget.messaging?.isArchived(item.id) ?? false) == _showArchived,
    );
    final query = search.text.trim().toLowerCase();
    if (query.isNotEmpty) {
      result = result.where((item) {
        final title = _conversationTitle(context, item).toLowerCase();
        return title.contains(query) ||
            (item.peerAddress?.toLowerCase().contains(query) ?? false);
      });
    }
    return result.toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final folderController = LoomChatFoldersScope.maybeOf(context);
    final content = folderController == null
        ? _buildFolderedList(context, null)
        : AnimatedBuilder(
            animation: folderController,
            builder: (context, _) =>
                _buildFolderedList(context, folderController),
          );
    return PopScope<void>(
      canPop: !widget.active || !_searching,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && widget.active && _searching) {
          _closeSearch();
        }
      },
      child: content,
    );
  }

  Widget _buildFolderedList(
    BuildContext context,
    LoomChatFolderController? folderController,
  ) {
    final strings = LoomStrings.of(context);
    final palette = context.loom;
    final folders = _folders(folderController);
    final selectedIndex = _selectedIndex(folders);
    final messaging = widget.messaging;
    _syncPageController(selectedIndex);

    return Stack(
      children: [
        ColoredBox(
          color: palette.background,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 12, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: SizedBox(
                        key: _searchSurfaceKey,
                        height: math.max(
                          56,
                          MediaQuery.textScalerOf(context).scale(20) + 32,
                        ),
                        child: AnimatedSwitcher(
                          duration:
                              LoomAccessibility.fromContext(
                                context,
                              ).reduceMotion
                              ? Duration.zero
                              : const Duration(milliseconds: 240),
                          switchInCurve: Curves.linear,
                          switchOutCurve: Curves.linear,
                          transitionBuilder: (child, animation) {
                            if (child.key != const ValueKey('chat-search')) {
                              return FadeTransition(
                                opacity: animation,
                                child: child,
                              );
                            }
                            return LayoutBuilder(
                              builder: (context, constraints) {
                                final destination =
                                    Offset.zero & constraints.biggest;
                                final box = _searchSurfaceKey.currentContext
                                    ?.findRenderObject();
                                final source =
                                    _searchOrigin != null &&
                                        box is RenderBox &&
                                        box.hasSize
                                    ? box.globalToLocal(
                                            _searchOrigin!.topLeft,
                                          ) &
                                          _searchOrigin!.size
                                    : destination;
                                return Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    LoomContainerTransform(
                                      animation: animation,
                                      origin: source,
                                      destination: destination,
                                      radius: 24,
                                      child: Material(
                                        color: palette.surfaceElevated,
                                        child: child,
                                      ),
                                    ),
                                  ],
                                );
                              },
                            );
                          },
                          child: _searching
                              ? Row(
                                  key: const ValueKey('chat-search'),
                                  children: [
                                    IconButton(
                                      tooltip: tr(
                                        context,
                                        'Close search',
                                        'بستن جستجو',
                                      ),
                                      onPressed: _closeSearch,
                                      icon: const BackButtonIcon(),
                                    ),
                                    Expanded(
                                      child: TextField(
                                        autofocus: true,
                                        controller: search,
                                        textInputAction: TextInputAction.search,
                                        onChanged: (_) => setState(() {}),
                                        decoration: InputDecoration(
                                          hintText: strings.search,
                                          filled: false,
                                          border: InputBorder.none,
                                          enabledBorder: InputBorder.none,
                                          focusedBorder: InputBorder.none,
                                        ),
                                      ),
                                    ),
                                  ],
                                )
                              : Row(
                                  key: const ValueKey('chat-title'),
                                  children: [
                                    Expanded(
                                      child: _SyncTitle(messaging: messaging),
                                    ),
                                    Builder(
                                      builder: (anchor) => IconButton(
                                        tooltip: strings.search,
                                        onPressed: () {
                                          _searchOrigin = LoomOrigin.of(anchor);
                                          setState(() => _searching = true);
                                        },
                                        icon: const Icon(
                                          LoomIcons.search_rounded,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                        ),
                      ),
                    ),
                    _LoomMenuButton(
                      label: tr(context, 'More options', 'گزینه‌های بیشتر'),
                      heading: 'Loom',
                      onSelected: (value) =>
                          Navigator.pushNamed(context, switch (value) {
                            'appearance' => '/settings/appearance',
                            'folders' => '/settings/chat-folders',
                            'server' => '/node-detail',
                            _ => '/profile',
                          }),
                      items: [
                        (
                          'appearance',
                          LoomIcons.palette_outlined,
                          tr(context, 'Appearance', 'ظاهر'),
                        ),
                        (
                          'folders',
                          LoomIcons.folder_outlined,
                          tr(context, 'Chat folders', 'پوشه‌های گفتگو'),
                        ),
                        (
                          'server',
                          LoomIcons.dns_outlined,
                          tr(context, 'Server', 'سرور'),
                        ),
                        (
                          'profile',
                          LoomIcons.person_outline_rounded,
                          tr(context, 'Your profile', 'پروفایل شما'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (_showArchived ||
                  (messaging?.conversations.any(
                        (c) => messaging.isArchived(c.id),
                      ) ??
                      false))
                ListTile(
                  dense: true,
                  leading: Icon(
                    _showArchived
                        ? LoomIcons.arrow_back_rounded
                        : LoomIcons.archive_outlined,
                  ),
                  title: Text(
                    _showArchived
                        ? tr(context, 'Back to chats', 'بازگشت به گفتگوها')
                        : tr(context, 'Archived chats', 'گفتگوهای بایگانی‌شده'),
                  ),
                  onTap: () => setState(() => _showArchived = !_showArchived),
                ),
              if (folders.length > 1)
                SizedBox(
                  height: 50,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    separatorBuilder: (_, __) => const SizedBox(width: 4),
                    itemCount: folders.length,
                    itemBuilder: (context, index) => ChoiceChip(
                      selected: selectedIndex == index,
                      showCheckmark: false,
                      label: Text(
                        loomChatFolderDisplayName(context, folders[index]),
                      ),
                      onSelected: (_) => _selectFolder(folders, index),
                      side: BorderSide.none,
                      backgroundColor: Colors.transparent,
                      selectedColor: palette.primary.withAlphaFraction(.13),
                      labelStyle: TextStyle(
                        color: selectedIndex == index
                            ? palette.primary
                            : palette.textSecondary,
                        fontWeight: selectedIndex == index
                            ? FontWeight.w700
                            : FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              Expanded(
                child: LoomFolderSwipeBoundary(
                  onNext: widget.onNextSection,
                  child: PageView.builder(
                    physics: const ClampingScrollPhysics(),
                    controller: _folderPageController,
                    itemCount: folders.length,
                    onPageChanged: (index) {
                      if (index < 0 || index >= folders.length) {
                        return;
                      }
                      setState(() => _selectedFolderId = folders[index].id);
                    },
                    itemBuilder: (context, index) => _FolderConversationPage(
                      key: ValueKey(folders[index].id),
                      preview: widget.preview,
                      folder: folders[index],
                      conversations: _filteredConversations(folders[index]),
                      messaging: messaging,
                      selectedConversationId: widget.selectedConversationId,
                      onConversationSelected: widget.onConversationSelected,
                      onConversationOrigin: widget.onConversationOrigin,
                      onNewChat: widget.onNewChat,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        if (MediaQuery.viewInsetsOf(context).bottom == 0)
          Positioned.fill(
            child: LoomCreateDial(
              onChat: widget.onNewChat,
              onGroups: widget.preview
                  ? null
                  : () async {
                      final id = await showLoomNewGroup(context);
                      if (!mounted || !context.mounted || id == null) return;
                      widget.onConversationSelected(id);
                    },
              onContact: () => Navigator.push<void>(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => const LoomPeopleScreen(focusSearch: true),
                ),
              ),
              onCall: () => Navigator.push<void>(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => const LoomPeopleScreen(selectForCall: true),
                ),
              ),
              onSaved: () async {
                final messenger = widget.messaging;
                if (messenger == null) {
                  return;
                }
                await messenger.open();
                await messenger.restoreSavedConversation();
                final saved = messenger.conversations
                    .where((c) => c.kind == models.LoomConversationKind.self)
                    .firstOrNull;
                if (!mounted || !context.mounted) {
                  return;
                }
                if (saved != null) {
                  widget.onConversationSelected(saved.id);
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        tr(
                          context,
                          'Saved messages are not ready. Reopen your account and try again.',
                          'پیام‌های ذخیره‌شده هنوز آماده نیست. حساب را دوباره باز کنید و تلاش کنید.',
                        ),
                      ),
                    ),
                  );
                }
              },
            ),
          ),
      ],
    );
  }
}

class _FolderConversationPage extends StatelessWidget {
  const _FolderConversationPage({
    this.onConversationOrigin,
    required this.preview,
    required this.folder,
    required this.conversations,
    required this.messaging,
    required this.selectedConversationId,
    required this.onConversationSelected,
    required this.onNewChat,
    super.key,
  });

  final bool preview;
  final LoomChatFolderDefinition folder;
  final List<models.LoomConversation> conversations;
  final LoomMessagingSessionController? messaging;
  final String? selectedConversationId;
  final ValueChanged<String> onConversationSelected;
  final void Function(String, Rect?)? onConversationOrigin;
  final VoidCallback onNewChat;

  @override
  Widget build(BuildContext context) {
    if (preview) {
      return ListView.builder(
        padding: const EdgeInsets.only(bottom: 164),
        itemCount: LoomPreviewData.conversations.length,
        itemBuilder: (context, index) {
          final item = LoomPreviewData.conversations[index];
          return Builder(
            builder: (rowContext) => LoomChatRow(
              draftLabel: tr(context, 'Draft', 'پیش‌نویس'),
              typingLabel: tr(context, 'typing…', 'در حال نوشتن…'),
              name: item.name,
              preview: item.preview,
              time: item.time,
              unread: item.unread,
              presence: item.presence,
              muted: item.muted,
              pinned: item.pinned,
              draft: item.draft,
              typing: item.typing,
              delivery: item.delivery,
              selected: false,
              onTap: () {
                onConversationOrigin?.call(
                  'preview',
                  LoomOrigin.of(rowContext),
                );
                onConversationSelected('preview');
              },
            ),
          );
        },
      );
    }

    if (conversations.isEmpty) {
      return folder.locked
          ? ListView(
              padding: const EdgeInsets.only(bottom: 164),
              children: [
                SizedBox(height: 360, child: _EmptyChats(onNewChat: onNewChat)),
              ],
            )
          : _EmptyFolderState(folder: folder, onNewChat: onNewChat);
    }

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 164),
      itemCount: conversations.length,
      itemBuilder: (context, index) {
        final conversation = conversations[index];
        final messages =
            messaging?.visibleMessagesFor(conversation.id) ?? const [];
        final latest = messages.isEmpty ? null : messages.first;
        final mine =
            latest != null &&
            messaging?.onboarding.receipt?.address.toLowerCase() ==
                latest.record.senderAddress.toLowerCase();
        return Builder(
          builder: (rowContext) => GestureDetector(
            onSecondaryTapDown: messaging == null
                ? null
                : (details) async {
                    final action = await _conversationContextMenu(
                      rowContext,
                      conversation,
                      messaging!,
                      position: details.globalPosition,
                    );
                    if (action != null && rowContext.mounted) {
                      if (action == 'details' &&
                          conversation.peerAddress != null) {
                        Navigator.push<void>(
                          rowContext,
                          MaterialPageRoute(
                            builder: (_) => LoomPeerProfileScreen(
                              address: conversation.peerAddress!,
                              displayName: _conversationTitle(
                                rowContext,
                                conversation,
                              ),
                              identityId: messaging!.peerIdentityId(
                                conversation.peerAddress,
                              ),
                            ),
                          ),
                        );
                      } else {
                        await _manageConversation(
                          rowContext,
                          action,
                          conversation,
                          messaging!,
                        );
                      }
                    }
                  },
            onLongPress: messaging == null
                ? null
                : () async {
                    final action = await _conversationContextMenu(
                      rowContext,
                      conversation,
                      messaging!,
                    );
                    if (action != null && rowContext.mounted) {
                      if (action == 'details' &&
                          conversation.peerAddress != null) {
                        Navigator.push<void>(
                          rowContext,
                          MaterialPageRoute(
                            builder: (_) => LoomPeerProfileScreen(
                              address: conversation.peerAddress!,
                              displayName: _conversationTitle(
                                rowContext,
                                conversation,
                              ),
                              identityId: messaging!.peerIdentityId(
                                conversation.peerAddress,
                              ),
                            ),
                          ),
                        );
                      } else {
                        await _manageConversation(
                          rowContext,
                          action,
                          conversation,
                          messaging!,
                        );
                      }
                    }
                  },
            child: LoomChatRow(
              key: ValueKey(conversation.id),
              draftLabel: tr(context, 'Draft', 'پیش‌نویس'),
              typingLabel: tr(context, 'typing…', 'در حال نوشتن…'),
              name: _conversationTitle(context, conversation),
              avatar: conversation.kind == models.LoomConversationKind.group
                  ? LoomGroupAvatar(
                      groupId: conversation.id,
                      label: _conversationTitle(context, conversation),
                      groups: messaging?.groupsController,
                    )
                  : LoomOwnAvatar(
                      name: _conversationTitle(context, conversation),
                      size: LoomSizing.avatar,
                      identityId:
                          conversation.kind == models.LoomConversationKind.self
                          ? messaging?.onboarding.committedIdentity?.identityId
                          : messaging?.peerIdentityId(conversation.peerAddress),
                    ),
              preview:
                  latest?.text ??
                  (conversation.kind == models.LoomConversationKind.direct
                      ? tr(context, 'End-to-end encrypted', 'رمزگذاری سرتاسری')
                      : tr(
                          context,
                          'Encrypted conversation',
                          'گفتگوی رمزگذاری‌شده',
                        )),
              time: latest == null ? '' : _shortTime(latest.record.createdAt),
              unread: conversation.unreadCount,
              presence: false,
              muted: conversation.isMuted,
              pinned: conversation.isPinned,
              delivery: mine
                  ? _designDelivery(latest.record.deliveryState)
                  : LoomDeliveryState.none,
              selected:
                  MediaQuery.sizeOf(context).width >=
                      LoomBreakpoints.expanded &&
                  selectedConversationId == conversation.id,
              onTap: () {
                onConversationOrigin?.call(
                  conversation.id,
                  LoomOrigin.of(rowContext),
                );
                onConversationSelected(conversation.id);
              },
            ),
          ),
        );
      },
    );
  }
}

class _EmptyFolderState extends StatelessWidget {
  const _EmptyFolderState({required this.folder, required this.onNewChat});

  final LoomChatFolderDefinition folder;
  final VoidCallback onNewChat;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.fromLTRB(24, 72, 24, 92),
    children: [
      Icon(LoomIcons.folder_outlined, size: 44, color: context.loom.textMuted),
      const SizedBox(height: LoomSpacing.sm),
      Text(
        tr(context, 'No chats in this folder', 'گفتگویی در این پوشه نیست'),
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.titleSmall,
      ),
      const SizedBox(height: LoomSpacing.xs),
      Text(
        loomChatFolderDescription(context, folder),
        textAlign: TextAlign.center,
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: context.loom.textSecondary),
      ),
      const SizedBox(height: LoomSpacing.md),
      Wrap(
        alignment: WrapAlignment.center,
        spacing: LoomSpacing.xs,
        runSpacing: LoomSpacing.xs,
        children: [
          FilledButton.icon(
            onPressed: onNewChat,
            icon: const Icon(LoomIcons.add_rounded),
            label: Text(tr(context, 'New chat', 'گفتگوی جدید')),
          ),
          OutlinedButton.icon(
            onPressed: () =>
                Navigator.pushNamed(context, '/settings/chat-folders'),
            icon: const Icon(LoomIcons.tune_rounded),
            label: Text(tr(context, 'Manage folders', 'مدیریت پوشه‌ها')),
          ),
        ],
      ),
    ],
  );
}

class _EmptyChats extends StatelessWidget {
  const _EmptyChats({required this.onNewChat});

  final VoidCallback onNewChat;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(LoomSpacing.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            LoomIcons.forum_outlined,
            size: 42,
            color: context.loom.textMuted,
          ),
          const SizedBox(height: LoomSpacing.sm),
          Text(
            tr(context, 'No conversations yet.', 'هنوز گفتگویی ندارید.'),
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: LoomSpacing.xs),
          Text(
            tr(
              context,
              'Find a real Loom identity and start an encrypted chat.',
              'یک هویت واقعی لوم پیدا کنید و گفتگوی رمزگذاری‌شده شروع کنید.',
            ),
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: context.loom.textSecondary),
          ),
          const SizedBox(height: LoomSpacing.md),
          FilledButton.icon(
            onPressed: onNewChat,
            icon: const Icon(LoomIcons.chat_bubble_outline_rounded),
            label: Text(tr(context, 'New chat', 'گفتگوی جدید')),
          ),
        ],
      ),
    ),
  );
}

class _LiveMessageBubble extends StatelessWidget {
  const _LiveMessageBubble({
    required this.message,
    required this.ownAddress,
    this.onActions,
    this.onReply,
    this.quotedText,
    this.quotedAuthor,
    this.content,
    this.onQuoteTap,
    this.grouped = false,
    this.highlighted = false,
  });

  final LoomVisibleMessage message;
  final String? ownAddress;
  final VoidCallback? onActions;
  final VoidCallback? onReply;
  final String? quotedText;
  final String? quotedAuthor;
  final Widget? content;
  final VoidCallback? onQuoteTap;
  final bool grouped, highlighted;

  @override
  Widget build(BuildContext context) {
    final mine =
        ownAddress != null &&
        message.record.senderAddress.toLowerCase() == ownAddress!.toLowerCase();
    var presentation = switch (message.content.attachment?['kind']) {
      'image' =>
        message.content.attachment?['sticker'] == true
            ? LoomMessagePresentation.sticker
            : LoomMessagePresentation.photo,
      'audio' => LoomMessagePresentation.voice,
      'video' => LoomMessagePresentation.video,
      'video_note' => LoomMessagePresentation.roundVideo,
      _ => LoomMessagePresentation.text,
    };
    final location = message.content.location;
    if (location != null) {
      presentation = location['session'] != null
          ? LoomMessagePresentation.liveLocation
          : LoomMessagePresentation.location;
    }
    return LoomMessageBubble(
      presentation: presentation,
      onLinkTap: (uri) async {
        if (models.LoomGroupInviteLink.tryParse(uri.toString()) != null) {
          await Navigator.push<void>(
            context,
            MaterialPageRoute<void>(
              builder: (_) => LoomGroupJoinScreen(initialLink: uri.toString()),
            ),
          );
          return;
        }
        try {
          if (!await launchUrl(uri, mode: LaunchMode.externalApplication) &&
              context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  tr(context, 'Could not open link', 'باز کردن لینک ممکن نشد'),
                ),
              ),
            );
          }
        } catch (_) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  tr(context, 'Could not open link', 'باز کردن لینک ممکن نشد'),
                ),
              ),
            );
          }
        }
      },
      text: message.readable
          ? message.content.text
          : tr(
              context,
              'Security verification/decryption failed',
              'تأیید امنیتی/رمزگشایی ناموفق بود',
            ),
      onActions: onActions,
      onReply: onReply,
      quotedText: quotedText,
      quotedAuthor: quotedAuthor,
      content: message.record.metadata['groupSenderLabel'] != null && !mine
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  message.record.metadata['groupSenderLabel'] as String,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(
                    context,
                  ).textTheme.labelSmall?.copyWith(color: context.loom.primary),
                ),
                if (content != null) content!,
              ],
            )
          : content,
      onQuoteTap: onQuoteTap,
      grouped: grouped,
      highlighted: highlighted,
      replyLabel: tr(context, 'Reply', 'پاسخ'),
      time: message.record.metadata['groupTimestampKnown'] == false
          ? ''
          : _shortTime(message.record.createdAt),
      mine: mine,
      delivery: mine
          ? _designDelivery(message.record.deliveryState)
          : LoomDeliveryState.none,
      deliveryLabel: _deliveryLabel(context, message.record.deliveryState),
      transportLabel: switch (message.record.transportPath) {
        models.LoomMessageTransportPath.nearby => tr(
          context,
          'Nearby',
          'شبکهٔ نزدیک',
        ),
        models.LoomMessageTransportPath.hybrid => tr(
          context,
          'Nearby + internet',
          'نزدیک + اینترنت',
        ),
        _ => null,
      },
    );
  }
}

class _ConversationEmpty extends StatelessWidget {
  const _ConversationEmpty({required this.onNewChat});

  final VoidCallback onNewChat;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(LoomSpacing.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            LoomIcons.lock_outline_rounded,
            size: 52,
            color: context.loom.primary,
          ),
          const SizedBox(height: LoomSpacing.sm),
          Text(
            tr(
              context,
              'Select a conversation or start an encrypted chat.',
              'یک گفتگو را انتخاب کنید یا گفتگوی رمزگذاری‌شده شروع کنید.',
            ),
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: LoomSpacing.md),
          OutlinedButton.icon(
            onPressed: onNewChat,
            icon: const Icon(LoomIcons.people_outline_rounded),
            label: Text(tr(context, 'Find people', 'پیدا کردن افراد')),
          ),
        ],
      ),
    ),
  );
}

class _DetailsPane extends StatelessWidget {
  const _DetailsPane({
    required this.preview,
    required this.messaging,
    required this.conversation,
  });

  final bool preview;
  final LoomMessagingSessionController? messaging;
  final models.LoomConversation? conversation;

  @override
  Widget build(BuildContext context) {
    if (preview) {
      const profile = LoomPreviewData.profile;
      return ColoredBox(
        color: context.loom.background,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Center(
              child: LoomAvatar(
                label: profile.name,
                size: 92,
                presence: true,
                presenceLabel: tr(context, 'Online', 'آنلاین'),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              profile.name,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            Text(
              profile.address,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 22),
            LoomSettingsGroup(
              children: [
                LoomSettingsRow(
                  icon: LoomIcons.photo_library_outlined,
                  title: tr(context, 'Shared media', 'رسانه‌های مشترک'),
                ),
                LoomSettingsRow(
                  icon: LoomIcons.notifications_none_rounded,
                  title: tr(context, 'Notifications', 'اعلان‌ها'),
                ),
                LoomSettingsRow(
                  icon: LoomIcons.verified_user_outlined,
                  title: tr(context, 'Verify identity', 'تأیید هویت'),
                  showDivider: false,
                ),
              ],
            ),
          ],
        ),
      );
    }

    if (conversation == null) {
      return ColoredBox(
        color: context.loom.background,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(LoomSpacing.lg),
            child: Text(
              tr(
                context,
                'Select a conversation to see its details.',
                'برای دیدن جزئیات، یک گفتگو را انتخاب کنید.',
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    final selectedConversation = conversation!;
    final name = _conversationTitle(context, selectedConversation);
    return ColoredBox(
      color: context.loom.background,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Center(child: LoomAvatar(label: name, size: 92)),
          const SizedBox(height: 12),
          Text(
            name,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          if (selectedConversation.peerAddress != null)
            Directionality(
              textDirection: TextDirection.ltr,
              child: Text(
                selectedConversation.peerAddress!,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          const SizedBox(height: 22),
          LoomSettingsGroup(
            children: [
              LoomSettingsRow(
                icon: LoomIcons.verified_user_outlined,
                title: tr(context, 'Security', 'امنیت'),
                subtitle: _conversationSecurityLabel(
                  context,
                  selectedConversation,
                ),
                onTap: () => Navigator.pushNamed(context, '/security'),
              ),
              LoomSettingsRow(
                icon: LoomIcons.photo_library_outlined,
                title: tr(context, 'Shared media', 'رسانه‌های مشترک'),
                onTap: () =>
                    Navigator.pushNamed(context, '/settings/shared-media'),
              ),
              LoomSettingsRow(
                icon: LoomIcons.notifications_none_rounded,
                title: tr(context, 'Notifications', 'اعلان‌ها'),
                showDivider: false,
                onTap: () =>
                    Navigator.pushNamed(context, '/settings/notifications'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SettingsShortcut extends StatelessWidget {
  const _SettingsShortcut({
    required this.icon,
    required this.color,
    required this.label,
    required this.onTap,
  });
  final IconData icon;
  final Color color;
  final String label;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => Material(
    color: context.loom.surface,
    borderRadius: BorderRadius.circular(18),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 16),
        child: Column(
          children: [
            Icon(icon, color: color, size: 25),
            const SizedBox(height: 8),
            Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 2,
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ],
        ),
      ),
    ),
  );
}

class _SettingsPane extends StatelessWidget {
  const _SettingsPane({required this.messaging});

  final LoomMessagingSessionController? messaging;

  @override
  Widget build(BuildContext context) {
    final palette = context.loom;
    final receipt = messaging?.onboarding.receipt;
    final onboarding = messaging == null
        ? null
        : LoomOnboardingScope.of(context);
    final profileName = onboarding?.displayName.trim().isNotEmpty == true
        ? onboarding!.displayName
        : onboarding?.username.trim().isNotEmpty == true
        ? onboarding!.username
        : tr(context, 'My profile', 'پروفایل من');
    final groups = <List<(IconData, String, String?)>>[
      [
        (
          LoomIcons.person_outline_rounded,
          tr(context, 'My Profile', 'پروفایل من'),
          '/profile',
        ),
      ],
      [
        (
          LoomIcons.notifications_none_rounded,
          tr(context, 'Notifications', 'اعلان‌ها'),
          '/settings/notifications',
        ),
        (
          LoomIcons.lock_outline_rounded,
          tr(context, 'Privacy', 'حریم خصوصی'),
          '/settings/privacy',
        ),
        (
          LoomIcons.storage_outlined,
          tr(context, 'Data and Storage', 'داده و ذخیره‌سازی'),
          '/settings/storage',
        ),
        (
          LoomIcons.folder_outlined,
          tr(context, 'Chat Folders', 'پوشه‌های گفتگو'),
          '/settings/chat-folders',
        ),
        (
          LoomIcons.palette_outlined,
          tr(context, 'Appearance', 'ظاهر'),
          '/settings/appearance',
        ),
        (
          LoomIcons.near_me_outlined,
          tr(context, 'Nearby', 'نزدیک'),
          '/settings/nearby',
        ),
      ],
      [
        (
          LoomIcons.devices_outlined,
          tr(context, 'Devices', 'دستگاه‌ها'),
          '/security',
        ),
        (
          LoomIcons.language_rounded,
          tr(context, 'Language', 'زبان'),
          '/settings/language',
        ),
        (
          LoomIcons.info_outline_rounded,
          tr(context, 'About Loom', 'درباره لوم'),
          '/settings/about',
        ),
      ],
    ];
    final username = onboarding?.username.trim();
    final ownId = onboarding?.committedIdentity?.identityId;
    final subtitles = <String, String>{
      '/settings/notifications': tr(
        context,
        'Sounds and incoming calls',
        'صداها و تماس‌های ورودی',
      ),
      '/settings/privacy': tr(
        context,
        'App lock and encryption',
        'قفل برنامه و رمزگذاری',
      ),
      '/settings/storage': tr(
        context,
        'Messages stored on this device',
        'پیام‌های ذخیره‌شده روی این دستگاه',
      ),
      '/settings/chat-folders': tr(
        context,
        'Organize your conversations',
        'مرتب‌سازی گفتگوها',
      ),
      '/settings/appearance': tr(
        context,
        'Theme and glass effects',
        'تم و جلوه‌های شیشه‌ای',
      ),
      '/settings/nearby': tr(
        context,
        'Messaging without internet',
        'پیام‌رسانی بدون اینترنت',
      ),
      '/security': tr(
        context,
        'Sessions and device security',
        'نشست‌ها و امنیت دستگاه',
      ),
      '/settings/language': tr(context, 'English · فارسی', 'فارسی · English'),
      '/settings/about': tr(
        context,
        'Version and app information',
        'نسخه و اطلاعات برنامه',
      ),
    };
    return ColoredBox(
      color: palette.background,
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: ListView(
            key: const ValueKey('settings-scroll'),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 112),
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      LoomStrings.of(context).settings,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  _RoundAction(
                    icon: LoomIcons.search_rounded,
                    tooltip: tr(context, 'Search settings', 'جستجوی تنظیمات'),
                    onTap: () => unawaited(
                      _searchSettings(
                        context,
                        groups.expand((group) => group).toList(growable: false),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              Semantics(
                button: true,
                child: InkWell(
                  key: const ValueKey('settings-profile-card'),
                  borderRadius: BorderRadius.circular(18),
                  onTap: () => Navigator.pushNamed(context, '/profile'),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      children: [
                        LoomOwnAvatar(
                          name: profileName,
                          identityId: ownId,
                          size: 88,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          profileName,
                          maxLines: 2,
                          textAlign: TextAlign.center,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        if (username?.isNotEmpty == true) ...[
                          const SizedBox(height: 4),
                          Text(
                            '@$username',
                            key: const ValueKey('settings-username'),
                            textDirection: TextDirection.ltr,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: palette.textSecondary),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _SettingsShortcut(
                      icon: LoomIcons.qr_code_rounded,
                      color: palette.primary,
                      label: tr(context, 'My QR', 'کد من'),
                      onTap: receipt == null
                          ? null
                          : () => Navigator.pushNamed(context, '/profile-qr'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _SettingsShortcut(
                      icon: LoomIcons.edit_rounded,
                      color: palette.primary,
                      label: tr(context, 'Edit profile', 'ویرایش پروفایل'),
                      onTap: () => Navigator.pushNamed(context, '/profile'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _SettingsShortcut(
                      icon: LoomIcons.palette_outlined,
                      color: palette.primary,
                      label: tr(context, 'Appearance', 'ظاهر'),
                      onTap: () =>
                          Navigator.pushNamed(context, '/settings/appearance'),
                    ),
                  ),
                ],
              ),
              for (
                var groupIndex = 1;
                groupIndex < groups.length;
                groupIndex++
              ) ...[
                Padding(
                  padding: const EdgeInsetsDirectional.fromSTEB(16, 24, 16, 10),
                  child: Text(
                    groupIndex == 1
                        ? tr(context, 'Preferences', 'تنظیمات شخصی')
                        : tr(context, 'Account', 'حساب'),
                    style: Theme.of(
                      context,
                    ).textTheme.labelLarge?.copyWith(color: palette.primary),
                  ),
                ),
                LoomSettingsGroup(
                  children: [
                    for (
                      var index = 0;
                      index < groups[groupIndex].length;
                      index++
                    )
                      LoomSettingsRow(
                        icon: groups[groupIndex][index].$1,
                        title: groups[groupIndex][index].$2,
                        subtitle: subtitles[groups[groupIndex][index].$3],
                        showDivider: index != groups[groupIndex].length - 1,
                        onTap: groups[groupIndex][index].$3 == null
                            ? null
                            : () => Navigator.pushNamed(
                                context,
                                groups[groupIndex][index].$3!,
                              ),
                      ),
                  ],
                ),
              ],
              if (messaging != null) ...[
                const SizedBox(height: 24),
                LoomSettingsGroup(
                  children: [
                    LoomSettingsRow(
                      icon: LoomIcons.logout_rounded,
                      iconColor: palette.critical,
                      title: tr(context, 'Log out', 'خروج از حساب'),
                      showDivider: false,
                      onTap: () => _confirmLogout(context, messaging!),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 24),
              Center(
                child: Text(
                  'Loom',
                  style: Theme.of(
                    context,
                  ).textTheme.labelSmall?.copyWith(color: palette.textMuted),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static Future<void> _confirmLogout(
    BuildContext context,
    LoomMessagingSessionController messaging,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr(dialogContext, 'Log out?', 'از حساب خارج شوید؟')),
        content: Text(
          tr(
            dialogContext,
            'This removes the saved session and refresh credential from this device. Your Loom identity and recovery material stay on the device.',
            'نشست ذخیره‌شده و اعتبار ورود مجدد از این دستگاه حذف می‌شود. هویت لوم و اطلاعات بازیابی روی دستگاه باقی می‌ماند.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(tr(dialogContext, 'Cancel', 'لغو')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(tr(dialogContext, 'Log out', 'خروج')),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) {
      return;
    }
    await const LoomLogoutService().signOut(messaging.onboarding);
    if (!context.mounted) {
      return;
    }
    Navigator.of(
      context,
      rootNavigator: true,
    ).pushNamedAndRemoveUntil('/', (route) => false);
  }
}

class _RoundAction extends StatelessWidget {
  const _RoundAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: context.loom.surfaceElevated,
    shape: const CircleBorder(),
    child: IconButton(onPressed: onTap, icon: Icon(icon), tooltip: tooltip),
  );
}

String _conversationTitle(
  BuildContext context,
  models.LoomConversation conversation,
) {
  if (conversation.kind == models.LoomConversationKind.self) {
    return tr(context, 'Saved Messages', 'پیام‌های ذخیره‌شده');
  }
  final title = conversation.title?.trim();
  if (title != null && title.isNotEmpty) {
    return title;
  }
  return conversation.peerAddress ??
      tr(context, 'Direct chat', 'گفتگوی مستقیم');
}

String _conversationSecurityLabel(
  BuildContext context,
  models.LoomConversation conversation,
) => switch (conversation.kind) {
  models.LoomConversationKind.self => tr(
    context,
    'Encrypted for your identity',
    'رمزگذاری‌شده برای هویت شما',
  ),
  models.LoomConversationKind.direct => tr(
    context,
    'End-to-end encrypted',
    'رمزگذاری سرتاسری',
  ),
  models.LoomConversationKind.group => tr(
    context,
    'MLS encrypted group',
    'گروه رمزگذاری‌شده با MLS',
  ),
};

LoomDeliveryState _designDelivery(models.LoomDeliveryState state) =>
    switch (state) {
      models.LoomDeliveryState.queued => LoomDeliveryState.queued,
      models.LoomDeliveryState.sending => LoomDeliveryState.sending,
      models.LoomDeliveryState.sent => LoomDeliveryState.sent,
      models.LoomDeliveryState.delivered => LoomDeliveryState.delivered,
      models.LoomDeliveryState.read => LoomDeliveryState.read,
      models.LoomDeliveryState.failed => LoomDeliveryState.failed,
    };

String _deliveryLabel(BuildContext context, models.LoomDeliveryState state) =>
    switch (state) {
      models.LoomDeliveryState.queued => tr(context, 'Queued', 'در صف ارسال'),
      models.LoomDeliveryState.sending => tr(
        context,
        'Sending',
        'در حال ارسال',
      ),
      models.LoomDeliveryState.sent => tr(
        context,
        'Accepted by server',
        'پذیرفته‌شده توسط سرور',
      ),
      models.LoomDeliveryState.delivered => tr(
        context,
        'Delivered',
        'تحویل داده شد',
      ),
      models.LoomDeliveryState.read => tr(context, 'Read', 'خوانده شد'),
      models.LoomDeliveryState.failed => tr(context, 'Failed', 'ناموفق'),
    };

String _shortTime(DateTime value) {
  final local = value.toLocal();
  return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
}

void _showComingSoon(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}
