import 'package:flutter/material.dart';

import '../loom_glass.dart';
import '../loom_theme.dart';
import '../loom_tokens.dart';

class LoomGlassDialog extends StatelessWidget {
  const LoomGlassDialog({
    required this.title,
    required this.child,
    this.actions = const <Widget>[],
    super.key,
  });

  final String title;
  final Widget child;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Dialog(
        elevation: 0,
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(LoomSpacing.lg),
        child: LoomGlassSurface(
          strength: LoomGlassStrength.strong,
          radius: LoomRadii.sheet,
          padding: const EdgeInsets.all(LoomSpacing.md),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: LoomSizing.dialogMax),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: LoomSpacing.sm),
                Flexible(child: SingleChildScrollView(child: child)),
                if (actions.isNotEmpty) ...[
                  const SizedBox(height: LoomSpacing.md),
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: Wrap(spacing: LoomSpacing.xs, children: actions),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
}

@immutable
class LoomContextAction {
  const LoomContextAction({
    required this.label,
    required this.icon,
    this.onTap,
  });
  final String label;
  final IconData icon;
  final VoidCallback? onTap;
}

class LoomContextMenu extends StatelessWidget {
  const LoomContextMenu({required this.actions, super.key});
  final List<LoomContextAction> actions;

  @override
  Widget build(BuildContext context) {
    final p = context.loom;
    return LoomGlassSurface(
      strength: LoomGlassStrength.strong,
      radius: LoomRadii.control,
      padding: const EdgeInsets.symmetric(vertical: LoomSpacing.xxs),
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          minWidth: LoomSizing.contextMenuMin,
          maxWidth: LoomSizing.contextMenuMax,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final action in actions)
              InkWell(
                onTap: action.onTap,
                child: Container(
                  constraints: const BoxConstraints(
                    minHeight: LoomSizing.minTouch,
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: LoomSpacing.sm,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        action.icon,
                        size: LoomIconSize.standard,
                        color: p.textSecondary,
                      ),
                      const SizedBox(width: LoomSpacing.sm),
                      Expanded(child: Text(action.label)),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Shared quiet detail row for contacts, members and management actions.
class LoomDetailTile extends StatelessWidget {
  const LoomDetailTile({
    this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onTap,
    this.onLongPress,
    this.enabled = true,
    this.contentPadding,
    this.dense,
    this.shape,
    this.tileColor,
    this.isThreeLine = false,
    super.key,
  });
  final Widget? title, subtitle, leading, trailing;
  final VoidCallback? onTap, onLongPress;
  final bool enabled, isThreeLine;
  final bool? dense;
  final ShapeBorder? shape;
  final Color? tileColor;
  final EdgeInsetsGeometry? contentPadding;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: LoomGlassSurface(
          strength: LoomGlassStrength.weak,
          radius: LoomRadii.surface,
          padding: EdgeInsets.zero,
          child: Material(
            type: MaterialType.transparency,
            child: ListTile(
              title: title,
              subtitle: subtitle,
              leading: leading,
              trailing: trailing,
              onTap: onTap,
              onLongPress: onLongPress,
              enabled: enabled,
              dense: dense,
              isThreeLine: isThreeLine,
              contentPadding: contentPadding ??
                  const EdgeInsetsDirectional.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
              iconColor: context.loom.primary,
              textColor: context.loom.textPrimary,
              tileColor: tileColor,
              shape: shape ??
                  RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(LoomRadii.surface),
                  ),
            ),
          ),
        ),
      );
}
