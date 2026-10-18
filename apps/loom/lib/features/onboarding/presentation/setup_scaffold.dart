import 'package:loom_design/loom_design.dart';
import 'package:flutter/material.dart';

import '../../../app/loom_strings.dart';

/// Shared, scrollable setup chrome; forms remain reachable with a keyboard or
/// large text, and navigation is locked only while credentials are committed.
class LoomSetupScaffold extends StatelessWidget {
  const LoomSetupScaffold({
    required this.title,
    required this.subtitle,
    required this.children,
    this.actions,
    this.step,
    this.canPop = true,
    super.key,
  });
  final String title, subtitle;
  final List<Widget> children;
  final Widget? actions;
  final int? step;
  final bool canPop;

  @override
  Widget build(BuildContext context) {
    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    return PopScope(
      canPop: canPop,
      child: Scaffold(
        body: LoomSetupBackdrop(
          child: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 620),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final compact = constraints.maxHeight < 680;
                    return Padding(
                      padding: EdgeInsets.all(compact ? 16 : 24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          LoomSetupHeader(step: step, canPop: canPop),
                          SizedBox(height: compact ? 12 : 20),
                          Text(
                            title,
                            style: Theme.of(context).textTheme.headlineSmall
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 6),
                          if (!keyboardOpen) ...[
                            Text(
                              subtitle,
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(color: context.loom.textSecondary),
                            ),
                            const SizedBox(height: 16),
                          ],
                          Expanded(
                            child: SingleChildScrollView(
                              keyboardDismissBehavior:
                                  ScrollViewKeyboardDismissBehavior.onDrag,
                              child: LoomGlassSurface(
                                blur: false,
                                radius: LoomRadii.surface,
                                padding: EdgeInsets.all(compact ? 12 : 20),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: children,
                                ),
                              ),
                            ),
                          ),
                          if (actions != null) ...[
                            const SizedBox(height: 12),
                            SizedBox(width: double.infinity, child: actions!),
                          ],
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class LoomSetupHeader extends StatelessWidget {
  const LoomSetupHeader({this.step, this.canPop = true, super.key});
  final int? step;
  final bool canPop;

  @override
  Widget build(BuildContext context) {
    final current = step;
    final labels = [
      tr(context, 'Home server', 'سرور میزبان'),
      tr(context, 'You', 'تو'),
      tr(context, 'Your backup', 'پشتیبان تو'),
      tr(context, 'Ready', 'آماده'),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            if (Navigator.of(context).canPop()) ...[
              LoomGlassSurface(
                radius: 28,
                blur: false,
                child: SizedBox.square(
                  dimension: 48,
                  child: IconButton(
                    onPressed: canPop
                        ? () => Navigator.maybePop(context)
                        : null,
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).backButtonTooltip,
                    icon: const LoomDirectionalIcon(
                      LoomIcons.arrow_back_rounded,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
            ],
            const LoomRouteMark(size: 36),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Loom',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            if (current != null)
              Text(
                '$current / 4',
                textDirection: TextDirection.ltr,
                style: Theme.of(context).textTheme.labelMedium,
              ),
          ],
        ),
        if (current != null) ...[
          const SizedBox(height: 8),
          Semantics(
            label: tr(
              context,
              'Step $current of 4: ${labels[current - 1]}',
              'مرحلهٔ $current از ۴: ${labels[current - 1]}',
            ),
            child: ExcludeSemantics(
              child: Row(
                children: [
                  for (var index = 0; index < 4; index++)
                    Expanded(
                      child: AnimatedContainer(
                        duration:
                            LoomAccessibility.fromContext(context).reduceMotion
                            ? Duration.zero
                            : LoomMotion.component,
                        height: 4,
                        margin: EdgeInsetsDirectional.only(
                          end: index == 3 ? 0 : 6,
                        ),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(4),
                          color: index < current
                              ? context.loom.primary
                              : context.loom.borderStrong,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            labels[current - 1],
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ],
      ],
    );
  }
}

/// A quiet setup canvas instead of a pretend conversation wallpaper.
class LoomSetupBackdrop extends StatelessWidget {
  const LoomSetupBackdrop({required this.child, super.key});
  final Widget child;
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          context.loom.primary.withAlphaFraction(.14),
          context.loom.background,
          context.loom.primary.withAlphaFraction(.04),
        ],
        stops: const [0, .48, 1],
      ),
    ),
    child: Stack(
      children: [
        Positioned.fill(
          child: ColoredBox(
            color: context.loom.background.withAlphaFraction(.25),
          ),
        ),
        child,
      ],
    ),
  );
}

class LoomSetupEmblem extends StatelessWidget {
  const LoomSetupEmblem({required this.icon, this.size = 72, super.key});
  final IconData icon;
  final double size;
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: LoomGlassSurface(
      radius: size * .35,
      blur: false,
      child: SizedBox.square(
        dimension: size,
        child: Icon(icon, color: context.loom.primary, size: size * .42),
      ),
    ),
  );
}
