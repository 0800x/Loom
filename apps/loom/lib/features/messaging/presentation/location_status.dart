import 'dart:async';
import 'package:loom_design/loom_design.dart';
import 'package:flutter/material.dart';
import '../../../app/loom_strings.dart';

/// Only the status clock rebuilds. The map, message key and scroll anchor stay
/// intact; a missing GPS update is shown as stale rather than extrapolated.
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

class _LoomLocationStatusState extends State<LoomLocationStatus> {
  Timer? _clock;
  bool get active =>
      widget.location['stopped'] != true &&
      (widget.location['until'] as int) > DateTime.now().millisecondsSinceEpoch;
  @override
  void initState() {
    super.initState();
    _schedule();
  }

  @override
  void didUpdateWidget(covariant LoomLocationStatus old) {
    super.didUpdateWidget(old);
    _schedule();
  }

  void _schedule() {
    if (!active) {
      _clock?.cancel();
      _clock = null;
      return;
    }
    _clock ??= Timer.periodic(const Duration(seconds: 15), (_) {
      if (!mounted) return;
      _schedule();
      setState(() {});
    });
  }

  @override
  void dispose() {
    _clock?.cancel();
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
    final label = !active
        ? widget.location['stopped'] == true
              ? tr(context, 'Sharing stopped', 'اشتراک متوقف شد')
              : tr(context, 'Sharing expired', 'اشتراک پایان یافت')
        : age > 75
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: Theme.of(
            context,
          ).textTheme.labelMedium?.copyWith(color: widget.foreground),
        ),
        const SizedBox(height: 4),
        Text(
          updated,
          style: Theme.of(
            context,
          ).textTheme.labelSmall?.copyWith(color: widget.foreground),
        ),
        if (active && widget.onStop != null)
          TextButton.icon(
            onPressed: widget.onStop,
            style: TextButton.styleFrom(foregroundColor: widget.foreground),
            icon: const Icon(LoomIcons.stop_circle_outlined, size: 18),
            label: Text(tr(context, 'Stop sharing', 'توقف اشتراک')),
          ),
      ],
    );
  }
}
