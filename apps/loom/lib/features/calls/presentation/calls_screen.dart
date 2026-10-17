import 'dart:async';

import 'package:loom_calls/loom_calls.dart';
import 'package:loom_design/loom_design.dart';
import 'package:loom_models/loom_models.dart';
import 'package:loom_protocol/loom_protocol.dart';
import 'package:flutter/material.dart';

import '../../../app/loom_strings.dart';
import '../../people/presentation/people_screen.dart';
import '../application/call_session_controller.dart';
import 'call_error.dart';
import 'call_surfaces.dart';

class LoomCallsScreen extends StatefulWidget {
  const LoomCallsScreen({super.key, this.preview = false});

  /// Kept for Design Lab route compatibility. Production never renders fake
  /// call rows; preview mode uses the same empty/real-history surface.
  final bool preview;

  @override
  State<LoomCallsScreen> createState() => _LoomCallsScreenState();
}

class _LoomCallsScreenState extends State<LoomCallsScreen> {
  int filter = 0;
  bool _opened = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_opened || widget.preview) {
      return;
    }
    _opened = true;
    unawaited(LoomCallSessionScope.of(context).open());
  }

  @override
  Widget build(BuildContext context) {
    // Design Lab can host the shell without a signed-in session or call
    // provider. Its empty history must not start a real call controller.
    if (widget.preview) {
      return _buildHistory(context, const <LoomCallHistoryEntry>[]);
    }
    final calls = LoomCallSessionScope.of(context);
    return AnimatedBuilder(
      animation: calls,
      builder: (context, _) =>
          _buildHistory(context, calls.history, calls: calls),
    );
  }

  Widget _buildHistory(
    BuildContext context,
    List<LoomCallHistoryEntry> history, {
    LoomCallSessionController? calls,
  }) {
    final entries = filter == 0
        ? history
        : history.where((entry) => entry.missed).toList(growable: false);
    return Material(
      color: context.loom.background,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 100),
        children: [
          Row(
            children: [
              Text(
                LoomStrings.of(context).calls,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const Spacer(),
              IconButton.filledTonal(
                onPressed: widget.preview
                    ? null
                    : () => Navigator.of(context).push<void>(
                        MaterialPageRoute<void>(
                          builder: (_) => const LoomPeopleScreen(),
                        ),
                      ),
                icon: const Icon(LoomIcons.add_call),
                tooltip: tr(context, 'Start call', 'شروع تماس'),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (calls != null && calls.connectionError != null) ...[
            LoomGlassSurface(
              liveBackdrop: true,
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tr(
                      context,
                      'Call connection needs attention',
                      'اتصال تماس نیاز به بررسی دارد',
                    ),
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    callFailureMessage(
                      context,
                      LoomProtocolException(calls.connectionError!),
                    ),
                  ),
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: TextButton.icon(
                      onPressed: () => unawaited(calls.resumeAfterUnlock()),
                      icon: const Icon(LoomIcons.refresh_rounded),
                      label: Text(tr(context, 'Reconnect', 'اتصال دوباره')),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],
          _CallFilter(
            selected: filter,
            onSelected: (value) => setState(() => filter = value),
          ),
          const SizedBox(height: 12),
          if (entries.isEmpty)
            _EmptyCallsState(missedOnly: filter == 1)
          else
            for (final entry in entries)
              _CallRow(
                entry: entry,
                onDetails: () => _showDetails(context, entry),
                onCall: entry.peerAddress.isEmpty
                    ? null
                    : () => unawaited(
                        startAddressCallFromUi(
                          context,
                          entry.peerAddress,
                          entry.kind,
                        ),
                      ),
              ),
        ],
      ),
    );
  }

  void _showDetails(BuildContext context, LoomCallHistoryEntry entry) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  LoomAvatar(label: entry.peerDisplayName, size: 52),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          entry.peerDisplayName,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        if (entry.peerAddress.isNotEmpty)
                          Directionality(
                            textDirection: TextDirection.ltr,
                            child: Text(entry.peerAddress),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              _DetailLine(
                label: tr(context, 'Type', 'نوع'),
                value: entry.kind == LoomCallKind.video
                    ? tr(context, 'Video call', 'تماس ویدیویی')
                    : tr(context, 'Audio call', 'تماس صوتی'),
              ),
              _DetailLine(
                label: tr(context, 'Direction', 'جهت'),
                value: entry.direction == LoomCallDirection.incoming
                    ? tr(context, 'Incoming', 'ورودی')
                    : tr(context, 'Outgoing', 'خروجی'),
              ),
              _DetailLine(
                label: tr(context, 'Result', 'نتیجه'),
                value: _outcomeLabel(context, entry.outcome),
              ),
              _DetailLine(
                label: tr(context, 'Started', 'شروع'),
                value: _timestamp(context, entry.startedAt),
              ),
              if (entry.answeredAt != null)
                _DetailLine(
                  label: tr(context, 'Answered', 'پاسخ'),
                  value: _timestamp(context, entry.answeredAt!),
                ),
              if (entry.endedAt != null)
                _DetailLine(
                  label: tr(context, 'Ended', 'پایان'),
                  value: _timestamp(context, entry.endedAt!),
                ),
              if (entry.duration > Duration.zero)
                _DetailLine(
                  label: tr(context, 'Duration', 'مدت'),
                  value: _duration(entry.duration),
                ),
              const SizedBox(height: 14),
              if (entry.peerAddress.isNotEmpty)
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () {
                      Navigator.pop(context);
                      unawaited(
                        startAddressCallFromUi(
                          this.context,
                          entry.peerAddress,
                          entry.kind,
                        ),
                      );
                    },
                    icon: Icon(
                      entry.kind == LoomCallKind.video
                          ? LoomIcons.videocam_rounded
                          : LoomIcons.call_rounded,
                    ),
                    label: Text(tr(context, 'Call again', 'تماس دوباره')),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CallFilter extends StatelessWidget {
  const _CallFilter({required this.selected, required this.onSelected});
  final int selected;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final palette = context.loom;
    final labels = <String>[
      tr(context, 'All', 'همه'),
      tr(context, 'Missed', 'از دست‌رفته'),
    ];
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: palette.surfaceMuted,
        borderRadius: BorderRadius.circular(LoomRadii.control),
      ),
      child: Row(
        children: [
          for (var index = 0; index < labels.length; index++)
            Expanded(
              child: InkWell(
                onTap: () => onSelected(index),
                borderRadius: BorderRadius.circular(LoomRadii.compact),
                child: AnimatedContainer(
                  duration: LoomMotion.component,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  decoration: BoxDecoration(
                    color: selected == index
                        ? palette.surface
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(LoomRadii.compact),
                  ),
                  child: Text(
                    labels[index],
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: selected == index
                          ? palette.primary
                          : palette.textSecondary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _EmptyCallsState extends StatelessWidget {
  const _EmptyCallsState({required this.missedOnly});
  final bool missedOnly;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 88),
    child: Column(
      children: [
        CircleAvatar(
          radius: 34,
          backgroundColor: context.loom.primary.withAlphaFraction(.12),
          child: Icon(
            missedOnly
                ? LoomIcons.call_missed_rounded
                : LoomIcons.call_outlined,
            size: 30,
            color: context.loom.primary,
          ),
        ),
        const SizedBox(height: 14),
        Text(
          missedOnly
              ? tr(context, 'No missed calls', 'تماس از دست‌رفته‌ای نیست')
              : tr(
                  context,
                  'No call history yet',
                  'هنوز سابقه تماسی وجود ندارد',
                ),
          style: Theme.of(context).textTheme.titleMedium,
        ),
      ],
    ),
  );
}

class _CallRow extends StatelessWidget {
  const _CallRow({
    required this.entry,
    required this.onDetails,
    required this.onCall,
  });

  final LoomCallHistoryEntry entry;
  final VoidCallback onDetails;
  final VoidCallback? onCall;

  @override
  Widget build(BuildContext context) {
    final palette = context.loom;
    final missed = entry.missed;
    final icon = missed
        ? LoomIcons.call_missed_rounded
        : entry.direction == LoomCallDirection.outgoing
        ? LoomIcons.call_made_rounded
        : LoomIcons.call_received_rounded;
    return InkWell(
      onTap: onDetails,
      borderRadius: BorderRadius.circular(LoomRadii.surface),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 9),
        child: Row(
          children: [
            LoomAvatar(label: entry.peerDisplayName, size: 48),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.peerDisplayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Icon(
                        icon,
                        size: 15,
                        color: missed ? palette.critical : palette.connectivity,
                      ),
                      const SizedBox(width: 4),
                      Icon(
                        entry.kind == LoomCallKind.video
                            ? LoomIcons.videocam_outlined
                            : LoomIcons.call_outlined,
                        size: 14,
                        color: palette.textSecondary,
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          _rowDetail(context, entry),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: missed
                                    ? palette.critical
                                    : palette.textSecondary,
                              ),
                        ),
                      ),
                    ],
                  ),
                  Text(
                    _rowTimestamp(context, entry.startedAt),
                    style: Theme.of(
                      context,
                    ).textTheme.labelSmall?.copyWith(color: palette.textMuted),
                  ),
                ],
              ),
            ),
            IconButton(
              onPressed: onCall,
              tooltip: entry.kind == LoomCallKind.video
                  ? tr(context, 'Video call', 'تماس ویدیویی')
                  : tr(context, 'Audio call', 'تماس صوتی'),
              icon: Icon(
                entry.kind == LoomCallKind.video
                    ? LoomIcons.videocam_outlined
                    : LoomIcons.call_outlined,
              ),
              color: palette.primary,
            ),
          ],
        ),
      ),
    );
  }
}

class _DetailLine extends StatelessWidget {
  const _DetailLine({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      children: [
        SizedBox(
          width: 96,
          child: Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: context.loom.textSecondary,
            ),
          ),
        ),
        Expanded(child: Text(value)),
      ],
    ),
  );
}

String _rowDetail(BuildContext context, LoomCallHistoryEntry entry) {
  final result = _outcomeLabel(context, entry.outcome);
  if (entry.duration <= Duration.zero) {
    return result;
  }
  return '$result · ${_duration(entry.duration)}';
}

String _outcomeLabel(BuildContext context, LoomCallHistoryOutcome outcome) =>
    switch (outcome) {
      LoomCallHistoryOutcome.answered => tr(
        context,
        'Answered',
        'پاسخ داده شد',
      ),
      LoomCallHistoryOutcome.missed => tr(context, 'Missed', 'از دست‌رفته'),
      LoomCallHistoryOutcome.declined => tr(context, 'Declined', 'رد شده'),
      LoomCallHistoryOutcome.busy => tr(context, 'Busy', 'مشغول'),
      LoomCallHistoryOutcome.failed => tr(context, 'Failed', 'ناموفق'),
      LoomCallHistoryOutcome.canceled => tr(context, 'Canceled', 'لغو شده'),
    };

String _timestamp(BuildContext context, DateTime value) {
  final local = value.toLocal();
  final material = MaterialLocalizations.of(context);
  final date = material.formatCompactDate(local);
  final time = material.formatTimeOfDay(TimeOfDay.fromDateTime(local));
  return '$date · $time';
}

String _duration(Duration value) {
  final total = value.inSeconds.clamp(0, 99 * 60 * 60);
  final hours = total ~/ 3600;
  final minutes = (total % 3600) ~/ 60;
  final seconds = total % 60;
  if (hours > 0) {
    return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }
  return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
}

String _rowTimestamp(BuildContext context, DateTime value) {
  final local = value.toLocal();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(local.year, local.month, local.day);
  final time = MaterialLocalizations.of(
    context,
  ).formatTimeOfDay(TimeOfDay.fromDateTime(local));
  if (day == today) return time;
  if (day == today.subtract(const Duration(days: 1))) {
    return '${tr(context, 'Yesterday', 'دیروز')} · $time';
  }
  return '${MaterialLocalizations.of(context).formatCompactDate(local)} · $time';
}
