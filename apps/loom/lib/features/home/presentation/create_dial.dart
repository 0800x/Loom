import 'dart:math' as math;

import 'package:loom_design/loom_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/loom_strings.dart';

/// Inline actions anchored to the create button; no sheet or modal route.
class LoomCreateDial extends StatefulWidget {
  const LoomCreateDial({
    required this.onChat,
    required this.onContact,
    required this.onCall,
    required this.onSaved,
    this.onGroups,
    super.key,
  });
  final VoidCallback onChat, onContact, onCall, onSaved;
  final VoidCallback? onGroups;
  @override
  State<LoomCreateDial> createState() => _LoomCreateDialState();
}

class _LoomCreateDialState extends State<LoomCreateDial> {
  bool _open = false;
  final _toggleFocus = FocusNode();
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // IndexedStack keeps Chats alive when another destination is selected.
    // An invisible menu must neither intercept Back nor reopen on return.
    if (!TickerMode.valuesOf(context).enabled) {
      _open = false;
    }
  }

  @override
  void dispose() {
    _toggleFocus.dispose();
    super.dispose();
  }

  void _close() {
    if (_open) {
      setState(() => _open = false);
      _toggleFocus.requestFocus();
    }
  }

  void _run(VoidCallback action) {
    _close();
    action();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.loom;
    final reduced = LoomAccessibility.fromContext(context).reduceMotion;
    final duration = reduced
        ? Duration.zero
        : const Duration(milliseconds: 220);
    final actions = <(IconData, String, Color, VoidCallback)>[
      if (widget.onGroups != null)
        (
          LoomIcons.people_outline_rounded,
          tr(context, 'New group', 'گروه جدید'),
          p.primary,
          widget.onGroups!,
        ),
      (
        LoomIcons.bookmark_border_rounded,
        tr(context, 'Saved messages', 'پیام‌های ذخیره‌شده'),
        p.secondary,
        widget.onSaved,
      ),
      (
        LoomIcons.call_outlined,
        tr(context, 'New call', 'تماس جدید'),
        p.primary,
        widget.onCall,
      ),
      (
        LoomIcons.person_add_alt_rounded,
        tr(context, 'Add contact', 'افزودن مخاطب'),
        p.primary,
        widget.onContact,
      ),
      (
        LoomIcons.chat_bubble_outline_rounded,
        tr(context, 'New chat', 'گفتگوی جدید'),
        context.loom.primary,
        widget.onChat,
      ),
    ];
    return PopScope<void>(
      key: const ValueKey('create-dial-pop-scope'),
      canPop: !_open,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          _close();
        }
      },
      child: CallbackShortcuts(
        bindings: {const SingleActivator(LogicalKeyboardKey.escape): _close},
        child: LayoutBuilder(
          builder: (context, constraints) {
            final menu = !_open
                ? const SizedBox.shrink()
                : ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: math.max(
                        0.0,
                        math.min(260.0, constraints.maxWidth - 36.0),
                      ),
                      maxHeight: math.max(0.0, constraints.maxHeight - 158.0),
                    ),
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          for (final action in actions)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: LoomReveal(
                                child: Row(
                                  mainAxisSize: MainAxisSize.max,
                                  mainAxisAlignment: MainAxisAlignment.end,
                                  children: [
                                    Flexible(
                                      child: GestureDetector(
                                        onTap: () => _run(action.$4),
                                        child: LoomGlassSurface(
                                          liveBackdrop: true,
                                          radius: 16,
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 12,
                                            vertical: 7,
                                          ),
                                          child: Text(
                                            action.$2,
                                            maxLines: 2,
                                            textAlign: TextAlign.end,
                                            style: Theme.of(
                                              context,
                                            ).textTheme.labelMedium,
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    SizedBox(
                                      width: 56,
                                      child: Center(
                                        child: LoomGlassSurface(
                                          liveBackdrop: true,
                                          radius: 26,
                                          padding: EdgeInsets.zero,
                                          child: SizedBox.square(
                                            dimension: 48,
                                            child: IconButton(
                                              tooltip: action.$2,
                                              color: action.$3,
                                              onPressed: () => _run(action.$4),
                                              icon: Icon(action.$1, size: 23),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  );
            return Stack(
              children: [
                if (_open)
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _close,
                      child: const SizedBox.expand(),
                    ),
                  ),
                PositionedDirectional(
                  end: 18,
                  bottom: 84,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      // A zero-duration AnimatedSize can re-enter layout
                      // when its child changes. Reduced motion uses the final
                      // layout directly, with no animation render object.
                      if (reduced)
                        menu
                      else
                        AnimatedSize(
                          duration: duration,
                          alignment: Alignment.bottomCenter,
                          curve: Curves.easeOutCubic,
                          child: menu,
                        ),
                      LoomGlassSurface(
                        liveBackdrop: true,
                        strength: LoomGlassStrength.strong,
                        radius: 28,
                        padding: EdgeInsets.zero,
                        child: SizedBox.square(
                          dimension: 56,
                          child: IconButton(
                            key: const ValueKey('create-dial-toggle'),
                            focusNode: _toggleFocus,
                            tooltip: _open
                                ? tr(context, 'Close menu', 'بستن منو')
                                : tr(context, 'Create', 'شروع'),
                            onPressed: () {
                              HapticFeedback.selectionClick();
                              _toggleFocus.requestFocus();
                              setState(() => _open = !_open);
                            },
                            icon: AnimatedRotation(
                              turns: _open ? .125 : 0,
                              duration: duration,
                              child: Icon(
                                LoomIcons.add_rounded,
                                size: 29,
                                color: context.loom.primary,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
