part of 'messenger_shell.dart';

/// Independent clipped backdrops let the wallpaper breathe between controls.
class _ConversationHeader extends StatelessWidget {
  const _ConversationHeader({
    required this.name,
    required this.saved,
    required this.avatar,
    required this.onProfile,
    required this.onSearch,
    required this.onMenu,
    this.onBack,
    this.onCall,
    this.status,
    this.online = false,
    this.conversation,
    this.archived = false,
  });
  final String name;
  final bool saved, online;
  final String? status;
  final Widget avatar;
  final VoidCallback? onBack, onProfile, onSearch, onCall;
  final ValueChanged<String> onMenu;
  final models.LoomConversation? conversation;
  final bool archived;

  Widget _glass(Widget child) =>
      LoomGlassSurface(liveBackdrop: true, radius: 32, child: child);

  @override
  Widget build(BuildContext context) => Row(
    children: [
      if (onBack != null) ...[
        _glass(
          SizedBox.square(
            dimension: 52,
            child: LoomPressable(
              child: IconButton(
                onPressed: onBack,
                tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                icon: const LoomDirectionalIcon(
                  LoomIcons.arrow_back_rounded,
                ),
                constraints: const BoxConstraints.tightFor(
                  width: 52,
                  height: 52,
                ),
                padding: EdgeInsets.zero,
              ),
            ),
          ),
        ),
        const SizedBox(width: 6),
      ],
      Expanded(
        child: _glass(
          InkWell(
            onTap: onProfile,
            borderRadius: BorderRadius.circular(32),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
              child: Row(
                children: [
                  if (saved)
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: context.loom.primary,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        LoomIcons.bookmark_border_rounded,
                        color: context.loom.onPrimary,
                        size: 24,
                      ),
                    )
                  else
                    avatar,
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        if (!saved && status != null)
                          Text(
                            status!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(
                                  color: online
                                      ? context.loom.primary
                                      : context.loom.textSecondary,
                                ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      const SizedBox(width: 6),
      _glass(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              onPressed: onSearch,
              tooltip: tr(context, 'Search messages', 'جستجوی پیام‌ها'),
              icon: const Icon(LoomIcons.search_rounded),
              constraints: const BoxConstraints(minWidth: 44, minHeight: 52),
            ),
            _LoomMenuButton(
              label: tr(context, 'Conversation menu', 'منوی گفتگو'),
              heading: name,
              onSelected: onMenu,
              items: [
                if (onCall != null)
                  (
                    'call',
                    LoomIcons.call_outlined,
                    tr(context, 'Call', 'تماس'),
                  ),
                (
                  'search',
                  LoomIcons.search_rounded,
                  tr(context, 'Search messages', 'جستجوی پیام‌ها'),
                ),
                (
                  'details',
                  LoomIcons.info_outline_rounded,
                  tr(context, 'Conversation details', 'جزئیات گفتگو'),
                ),
                (
                  'wallpaper',
                  LoomIcons.wallpaper_rounded,
                  tr(context, 'Chat wallpaper', 'پس‌زمینهٔ گفتگو'),
                ),
                (
                  'appearance',
                  LoomIcons.palette_outlined,
                  tr(context, 'Appearance', 'ظاهر'),
                ),
                if (conversation != null)
                  ..._conversationManagementItems(
                    context,
                    conversation!,
                    archived,
                  ),
                (
                  'guide',
                  LoomIcons.help_outline_rounded,
                  tr(context, 'Message status guide', 'راهنمای وضعیت پیام'),
                ),
              ],
            ),
          ],
        ),
      ),
    ],
  );
}

class _LoomMenuButton extends StatefulWidget {
  const _LoomMenuButton({
    required this.label,
    required this.heading,
    required this.items,
    required this.onSelected,
  });
  final String label, heading;
  final List<(String, IconData, String)> items;
  final ValueChanged<String> onSelected;
  @override
  State<_LoomMenuButton> createState() => _LoomMenuButtonState();
}

class _LoomMenuButtonState extends State<_LoomMenuButton> {
  final _controller = MenuController();
  final _anchorFocus = FocusNode();
  final _firstFocus = FocusNode();
  @override
  void dispose() {
    _anchorFocus.dispose();
    _firstFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final label = widget.label, heading = widget.heading, items = widget.items;
    final onSelected = widget.onSelected;
    final viewport = MediaQuery.sizeOf(context);
    final insets = MediaQuery.paddingOf(context);
    final maxWidth = (viewport.width - insets.horizontal - 24).clamp(
      160.0,
      320.0,
    );
    final view = View.of(context);
    final keyboard = math.max(
      MediaQuery.viewInsetsOf(context).bottom,
      view.viewInsets.bottom / view.devicePixelRatio,
    );
    final maxHeight = (viewport.height - insets.vertical - keyboard - 24).clamp(
      96.0,
      640.0,
    );
    return MenuAnchor(
      controller: _controller,
      childFocusNode: _anchorFocus,
      onOpen: () => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _controller.isOpen) _firstFocus.requestFocus();
      }),
      onClose: () {
        if (mounted) _anchorFocus.requestFocus();
      },
      useRootOverlay: true,
      consumeOutsideTap: true,
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(context.loom.surfaceElevated),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        minimumSize: WidgetStatePropertyAll(
          Size(maxWidth < 220 ? maxWidth : 220, 0),
        ),
        maximumSize: WidgetStatePropertyAll(Size(maxWidth, maxHeight)),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(LoomRadii.control),
          ),
        ),
      ),
      menuChildren: [
        if (heading.isNotEmpty)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              heading,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ),
        for (final (index, item) in items.indexed)
          MenuItemButton(
            focusNode: index == 0 ? _firstFocus : null,
            onPressed: () => onSelected(item.$1),
            style: const ButtonStyle(
              minimumSize: WidgetStatePropertyAll(
                Size(0, LoomSizing.minTouch),
              ),
            ),
            leadingIcon: Icon(item.$2, size: LoomIconSize.standard),
            child: Text(item.$3, softWrap: true),
          ),
      ],
      builder: (context, controller, _) => IconButton(
        tooltip: label,
        focusNode: _anchorFocus,
        icon: const Icon(LoomIcons.more_vert_rounded),
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }
}
