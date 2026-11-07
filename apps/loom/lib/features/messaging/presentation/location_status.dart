import 'dart:async';

import 'package:loom_design/loom_design.dart';
import 'package:flutter/material.dart';
import '../../../app/loom_strings.dart';

/// Modern live-location status card.
///
/// Only the status clock rebuilds. The map, message key and scroll anchor
/// stay intact; a missing GPS update is shown as stale rather than
/// extrapolated. The card uses a flat tinted surface with a pulsing status
/// dot, a remaining-time chip and a flat stop pill.
class LoomLocationStatus extends StatefulWidget {
  const LoomLocationStatus({
    required this.location,
    required this.foreground,
    this.onStop,
    super.key,
  });
  final Map<String, Object?> location;
  final Color foreground;
  final VoidCallback? onStop;
  @override
  State<LoomLocationStatus> createState() => _LoomLocationStatusState();
}

class _LoomLocationStatusState extends State<LoomLocationStatus>
    with SingleTickerProviderStateMixin {
  Timer? _clock;
  AnimationController? _pulse;
  bool? _reduceMotion;

  bool get active =>
      widget.location['stopped'] != true &&
      (widget.location['until'] as int) > DateTime.now().millisecondsSinceEpoch;

  @override
  void initState() {
    super.initState();
    _syncTimer();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Reading inherited accessibility state is only legal after dependencies
    // are mounted; initState must never touch context.
    final reduceMotion = LoomAccessibility.fromContext(context).reduceMotion;
    if (reduceMotion != _reduceMotion) {
      _reduceMotion = reduceMotion;
      _syncPulse();
    }
  }

  @override
  void didUpdateWidget(covariant LoomLocationStatus old) {
    super.didUpdateWidget(old);
    _syncTimer();
  }

  void _syncTimer() {
    if (!active) {
      _clock?.cancel();
      _clock = null;
      _pulse?.stop();
      return;
    }
    _clock ??= Timer.periodic(const Duration(seconds: 15), (_) {
      if (!mounted) return;
      _syncTimer();
      setState(() {});
    });
    _syncPulse();
  }

  void _syncPulse() {
    if (!active || (_reduceMotion ?? false)) {
      _pulse?.stop();
      return;
    }
    _pulse ??= AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
      lowerBound: .35,
      upperBound: 1,
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _clock?.cancel();
    _pulse?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final age = ((now - (widget.location['at'] as int)) / 1000).floor().clamp(
      0,
      86400,
    );
    final remaining = (((widget.location['until'] as int) - now) / 60000)
        .ceil();
    final stale = active && age > 75;
    final p = context.loom;
    final liveColor = Theme.of(context).brightness == Brightness.dark
        ? const Color(0xFF34D399)
        : const Color(0xFF059669);
    final staleColor = Theme.of(context).brightness == Brightness.dark
        ? const Color(0xFFFBBF24)
        : const Color(0xFFD97706);
    final accent = stale ? staleColor : liveColor;

    final label = !active
        ? widget.location['stopped'] == true
              ? tr(context, 'Sharing stopped', 'اشتراک متوقف شد')
              : tr(context, 'Sharing expired', 'اشتراک پایان یافت')
        : stale
        ? tr(context, 'No recent update', 'به‌روزرسانی تازه‌ای نرسیده')
        : tr(
            context,
            'Live · $remaining min left',
            'زنده · $remaining دقیقه باقی‌مانده',
          );
    final updated = age < 15
        ? tr(context, 'Updated just now', 'همین حالا به‌روز شد')
        : age < 60
        ? tr(context, 'Updated $age sec ago', '$age ثانیه پیش به‌روز شد')
        : tr(
            context,
            'Updated ${age ~/ 60} min ago',
            '${age ~/ 60} دقیقه پیش به‌روز شد',
          );

    final dot = AnimatedBuilder(
      animation: _pulse ?? kAlwaysCompleteAnimation,
      builder: (context, _) {
        final scale = active && !stale ? (_pulse?.value ?? 1) : 1.0;
        return Opacity(
          opacity: active && !stale ? .25 + .75 * scale : 1,
          child: Container(
            width: 11,
            height: 11,
            decoration: BoxDecoration(shape: BoxShape.circle, color: accent),
          ),
        );
      },
    );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: p.surfaceMuted,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: p.border),
      ),
      child: Row(
        children: [
          dot,
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: widget.foreground,
                  ),
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Icon(
                      LoomIcons.history_rounded,
                      size: 12,
                      color: widget.foreground.withAlphaFraction(.55),
                    ),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        updated,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: widget.foreground.withAlphaFraction(.6),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (active) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: accent.withAlphaFraction(.14),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(LoomIcons.schedule_rounded, size: 12, color: accent),
                  const SizedBox(width: 4),
                  Text(
                    tr(context, '$remaining min', '$remaining دقیقه'),
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: accent,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (active && widget.onStop != null) ...[
            const SizedBox(width: 6),
            TextButton.icon(
              onPressed: widget.onStop,
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 34),
              ),
              icon: const Icon(LoomIcons.stop_circle_outlined, size: 16),
              label: Text(tr(context, 'Stop', 'توقف')),
            ),
          ],
        ],
      ),
    );
  }
}
