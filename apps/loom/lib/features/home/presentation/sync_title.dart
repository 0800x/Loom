part of 'messenger_shell.dart';

/// Keep the page title stable; slow synchronization appears as a subtitle.
class _SyncTitle extends StatefulWidget {
  const _SyncTitle({required this.messaging});
  final LoomMessagingSessionController? messaging;

  @override
  State<_SyncTitle> createState() => _SyncTitleState();
}

class _SyncTitleState extends State<_SyncTitle> {
  Timer? _delay;
  bool _showProgress = false;

  bool get _busy =>
      widget.messaging?.isSynchronizing == true ||
      widget.messaging?.status == LoomMessagingSessionStatus.opening ||
      widget.messaging?.status == LoomMessagingSessionStatus.syncing;

  @override
  void initState() {
    super.initState();
    _observe();
  }

  @override
  void didUpdateWidget(covariant _SyncTitle oldWidget) {
    super.didUpdateWidget(oldWidget);
    _observe();
  }

  void _observe() {
    if (!_busy) {
      _delay?.cancel();
      _delay = null;
      _showProgress = false;
    } else if (!_showProgress && _delay == null) {
      _delay = Timer(const Duration(milliseconds: 450), () {
        if (mounted && _busy) setState(() => _showProgress = true);
      });
    }
  }

  @override
  void dispose() {
    _delay?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final messaging = widget.messaging;
    final offline =
        messaging?.status == LoomMessagingSessionStatus.offline ||
        messaging?.status == LoomMessagingSessionStatus.error;
    final queued = messaging?.pendingSendCount ?? 0;
    final label = tr(context, 'Loom', 'لوم');
    final hint = queued > 0
        ? tr(
            context,
            '$queued queued · automatic retry',
            '$queued پیام در صف · تلاش مجدد خودکار',
          )
        : offline
        ? tr(
            context,
            defaultTargetPlatform == TargetPlatform.windows
                ? 'Offline · click to retry'
                : 'Offline · tap to retry',
            'آفلاین · برای تلاش مجدد بزنید',
          )
        : tr(context, 'Messages are up to date', 'پیام‌ها به‌روز هستند');
    return Semantics(
      label: '$label. $hint',
      child: Tooltip(
        message: hint,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: messaging == null || _busy
              ? null
              : () => unawaited(messaging.retryQueuedMessages()),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                ),
                if (_showProgress || offline || queued > 0)
                  Row(
                    children: [
                      if (_showProgress) ...[
                        const SizedBox(
                          width: 10,
                          height: 10,
                          child: LoomBusyIndicator(),
                        ),
                        const SizedBox(width: 6),
                      ],
                      Flexible(
                        child: Text(
                          _showProgress
                              ? tr(context, 'Updating…', 'همگام‌سازی…')
                              : hint,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(color: context.loom.textSecondary),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
