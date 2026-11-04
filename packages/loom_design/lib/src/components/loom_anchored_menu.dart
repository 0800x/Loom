import 'package:flutter/material.dart';

/// A selectable row rendered by [LoomAnchoredMenu].
class LoomAnchoredMenuItem<T> {
  const LoomAnchoredMenuItem({
    required this.value,
    required this.label,
    this.leading,
    this.enabled = true,
    this.destructive = false,
  });

  final T value;
  final String label;
  final Widget? leading;
  final bool enabled;
  final bool destructive;
}

/// A lightweight menu anchored to its trigger widget.
class LoomAnchoredMenu<T> extends StatelessWidget {
  const LoomAnchoredMenu({
    required this.child,
    required this.items,
    required this.onSelected,
    this.offset = Offset.zero,
    this.menuWidth = 192,
    this.tooltip,
    super.key,
  });

  final Widget child;
  final List<LoomAnchoredMenuItem<T>> items;
  final ValueChanged<T> onSelected;
  final Offset offset;
  final double menuWidth;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<T>(
      tooltip: tooltip,
      offset: offset,
      position: PopupMenuPosition.under,
      constraints: BoxConstraints(minWidth: menuWidth, maxWidth: menuWidth),
      onSelected: onSelected,
      itemBuilder: (context) => [
        for (final item in items)
          PopupMenuItem<T>(
            value: item.value,
            enabled: item.enabled,
            child: Row(
              children: [
                if (item.leading != null) ...[
                  IconTheme(
                    data: IconThemeData(
                      color: item.destructive
                          ? Theme.of(context).colorScheme.error
                          : null,
                    ),
                    child: item.leading!,
                  ),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: Text(
                    item.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: item.destructive
                        ? TextStyle(color: Theme.of(context).colorScheme.error)
                        : null,
                  ),
                ),
              ],
            ),
          ),
      ],
      child: child,
    );
  }
}
