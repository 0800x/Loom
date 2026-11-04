import 'package:flutter/material.dart';
import 'package:loom_design/loom_design.dart';

import 'setup_scaffold.dart';

/// Shared onboarding frame for welcome, registration, recovery and sign-in.
/// It reuses the same setup backdrop/header as the newer setup scaffold, while
/// keeping the older full-screen content and fixed action-area contract.
class LoomOnboardingShell extends StatelessWidget {
  const LoomOnboardingShell({
    required this.title,
    required this.subtitle,
    required this.child,
    this.step,
    this.canPop = true,
    this.error,
    this.ctaLabel,
    this.ctaIcon,
    this.onCta,
    this.ctaBusy = false,
    this.headerTrailing,
    this.actions,
    super.key,
  });

  final int? step;
  final bool canPop;
  final String title;
  final String subtitle;
  final String? error;
  final String? ctaLabel;
  final IconData? ctaIcon;
  final VoidCallback? onCta;
  final bool ctaBusy;
  final Widget? headerTrailing;
  final Widget? actions;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    return PopScope(
      canPop: canPop,
      child: Scaffold(
        resizeToAvoidBottomInset: true,
        body: LoomSetupBackdrop(
          child: SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final compact = constraints.maxHeight < 680;
                final scrollWholePage = compact && !keyboardOpen;
                final content = Column(
                  mainAxisSize: scrollWholePage
                      ? MainAxisSize.min
                      : MainAxisSize.max,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    LoomSetupHeader(
                      step: step,
                      canPop: canPop,
                      trailing: headerTrailing,
                    ),
                    SizedBox(height: compact ? LoomSpacing.sm : LoomSpacing.ml),
                    Text(
                      title,
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    if (!keyboardOpen) ...[
                      const SizedBox(height: 6),
                      Text(
                        subtitle,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: context.loom.textSecondary,
                        ),
                      ),
                      const SizedBox(height: LoomSpacing.md),
                    ],
                    if (error != null) ...[
                      AnimatedSize(
                        duration: LoomMotion.component,
                        curve: LoomMotion.standard,
                        alignment: Alignment.topCenter,
                        child: LoomGlassSurface(
                          blur: false,
                          radius: LoomRadii.control,
                          padding: const EdgeInsets.symmetric(
                            horizontal: LoomSpacing.md,
                            vertical: LoomSpacing.sm,
                          ),
                          child: Row(
                            children: [
                              Icon(
                                LoomIcons.error_outline_rounded,
                                size: LoomIconSize.compact,
                                color: context.loom.critical,
                              ),
                              const SizedBox(width: LoomSpacing.sm),
                              Expanded(
                                child: Text(
                                  error!,
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(color: context.loom.critical),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: LoomSpacing.sm),
                    ],
                    if (scrollWholePage)
                      child
                    else
                      Expanded(
                        child: SingleChildScrollView(
                          keyboardDismissBehavior:
                              ScrollViewKeyboardDismissBehavior.onDrag,
                          child: child,
                        ),
                      ),
                    if (ctaLabel != null) ...[
                      const SizedBox(height: LoomSpacing.sm),
                      LoomOnboardingCta(
                        label: ctaLabel!,
                        icon: ctaIcon,
                        busy: ctaBusy,
                        onPressed: ctaBusy ? null : onCta,
                      ),
                    ],
                    if (actions != null) ...[
                      const SizedBox(height: LoomSpacing.xs),
                      actions!,
                    ],
                  ],
                );

                final padded = Padding(
                  padding: EdgeInsets.all(
                    compact ? LoomSpacing.md : LoomSpacing.lg,
                  ),
                  child: scrollWholePage
                      ? SingleChildScrollView(
                          keyboardDismissBehavior:
                              ScrollViewKeyboardDismissBehavior.onDrag,
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              minHeight:
                                  constraints.maxHeight - 2 * LoomSpacing.md,
                            ),
                            child: content,
                          ),
                        )
                      : content,
                );

                return Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 720),
                    child: padded,
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// Primary action used consistently by the onboarding flow.
class LoomOnboardingCta extends StatelessWidget {
  const LoomOnboardingCta({
    required this.label,
    required this.onPressed,
    this.icon,
    this.busy = false,
    super.key,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final Widget? leading = busy
        ? const SizedBox.square(
            dimension: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : icon == null
        ? null
        : Icon(icon);

    if (leading == null) {
      return SizedBox(
        width: double.infinity,
        child: FilledButton(
          onPressed: busy ? null : onPressed,
          child: Text(label),
        ),
      );
    }

    return SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        onPressed: busy ? null : onPressed,
        icon: leading,
        label: Text(label),
      ),
    );
  }
}

/// Quiet frame used around QR codes in pairing and recovery screens.
class LoomOnboardingQrFrame extends StatelessWidget {
  const LoomOnboardingQrFrame({
    required this.child,
    this.padding = const EdgeInsets.all(12),
    super.key,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: context.loom.surfaceElevated,
      borderRadius: BorderRadius.circular(LoomRadii.surface),
      border: Border.all(color: context.loom.borderStrong),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: .08),
          blurRadius: 20,
          offset: const Offset(0, 6),
        ),
      ],
    ),
    child: Padding(padding: padding, child: child),
  );
}
