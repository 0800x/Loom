import 'dart:async';

import 'package:loom_design/loom_design.dart';
import 'package:loom_transport/loom_transport.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/loom_strings.dart';
import '../../messaging/application/accepted_send_dtn_mirror.dart';
import '../../messaging/application/legacy_dtn_custody.dart';
import '../../messaging/application/nearby_dtn_service_controller.dart';
import '../../messaging/presentation/local_message_cleanup_screen.dart';

/// Offline DTN control centre, structured like the appearance panel:
/// a live status hero, grouped sections, a stats grid for the last round
/// and a collapsible debug snapshot.
class LoomNearbyModeScreen extends StatefulWidget {
  const LoomNearbyModeScreen({required this.controller, super.key});

  final LoomNearbyDtnServiceController controller;

  @override
  State<LoomNearbyModeScreen> createState() => _LoomNearbyModeScreenState();
}

class _LoomNearbyModeScreenState extends State<LoomNearbyModeScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _entrance;

  @override
  void initState() {
    super.initState();
    _entrance = AnimationController(
      vsync: this,
      duration: LoomAccessibility.fromContext(context).reduceMotion
          ? Duration.zero
          : const Duration(milliseconds: 280),
    )..forward();
  }

  @override
  void dispose() {
    _entrance.dispose();
    super.dispose();
  }

  Widget _entranceWrap(int index, Widget child) {
    if (LoomAccessibility.fromContext(context).reduceMotion) return child;
    final start = 0.06 * index;
    return AnimatedBuilder(
      animation: _entrance,
      builder: (context, _) {
        final t = ((_entrance.value - start) / (1 - start)).clamp(
          0.0,
          1.0,
        );
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, 12 * (1 - Curves.easeOutCubic.transform(t))),
            child: child,
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final active = controller.enabled;
        final status = _statusLabel(context, controller.status);
        final round = controller.lastRound;
        final debugSnapshot = _debugSnapshot();
        final sectionIndex = List<int>.generate(5, (i) => i);
        return Scaffold(
          appBar: LoomGlassAppBar(
            title: Text(tr(context, 'Nearby messaging', 'پیام‌رسانی نزدیک')),
          ),
          body: Align(
            alignment: Alignment.topCenter,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(
                LoomSpacing.md,
                LoomSpacing.sm,
                LoomSpacing.md,
                LoomSpacing.xl,
              ),
              children: [
                _entranceWrap(sectionIndex[0], _statusHero(context, active, status)),
                const SizedBox(height: LoomSpacing.lg),
                _entranceWrap(sectionIndex[1], _section(
                  context,
                  title: tr(context, 'Radio links', 'مسیرهای رادیویی'),
                  detail: tr(
                    context,
                    'Which bearers this device can use to exchange opaque DTN packets with nearby peers.',
                    'این دستگاه از کدام مسیرها می‌تواند بسته‌های رمز DTN را با همتاهای نزدیک جابه‌جا کند.',
                  ),
                  child: LoomSettingsGroup(
                    children: [
                      LoomSettingsRow(
                        icon: LoomIcons.bluetooth_disabled,
                        title: tr(context, 'Active bearer', 'مسیر فعال'),
                        trailing: Text(
                          controller.foregroundBearer == null
                              ? tr(context, 'None', 'هیچ‌کدام')
                              : _bearerLabel(controller.foregroundBearer!),
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: context.loom.textSecondary,
                          ),
                        ),
                      ),
                      LoomSettingsRow(
                        icon: LoomIcons.hub_outlined,
                        title: tr(
                          context,
                          'Supported bearers',
                          'مسیرهای پشتیبانی‌شده',
                        ),
                        showDivider: false,
                        trailing: Flexible(
                          child: Text(
                            controller.supportedBearers.isEmpty
                                ? tr(context, 'Not probed yet', 'هنوز بررسی نشده')
                                : controller.supportedBearers
                                      .map(_bearerLabel)
                                      .join(' • '),
                            textAlign: TextAlign.end,
                            style: Theme.of(
                              context,
                            ).textTheme.bodySmall?.copyWith(
                              color: context.loom.textSecondary,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                )),
                if (round != null) ...[
                  const SizedBox(height: LoomSpacing.lg),
                  _entranceWrap(sectionIndex[2], _section(
                    context,
                    title: tr(
                      context,
                      'Last DTN round',
                      'آخرین دور DTN',
                    ),
                    child: LoomSettingsGroup(
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(LoomSpacing.md),
                          child: Row(
                            children: [
                              _roundStat(
                                context,
                                '${round.discoveredCandidates}',
                                tr(context, 'discovered', 'کشف‌شده'),
                              ),
                              _roundStat(
                                context,
                                '${round.connectedCandidates}',
                                tr(context, 'connected', 'متصل'),
                              ),
                              _roundStat(
                                context,
                                '${round.outboundPacketsAccepted}',
                                tr(context, 'ACKs', 'تأیید'),
                              ),
                              _roundStat(
                                context,
                                '${round.inboundPacketsAccepted}',
                                tr(context, 'inbound', 'ورودی'),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  )),
                ],
                const SizedBox(height: LoomSpacing.lg),
                _entranceWrap(sectionIndex[3], _section(
                  context,
                  title: tr(context, 'Tools', 'ابزارها'),
                  child: LoomSettingsGroup(
                    children: [
                      LoomSettingsRow(
                        icon: LoomIcons.cleaning_services_outlined,
                        title: tr(
                          context,
                          'Local message cleanup',
                          'پاک‌سازی محلی پیام‌ها',
                        ),
                        onTap: () => Navigator.push<void>(
                          context,
                          MaterialPageRoute<void>(
                            builder: (_) => const LoomLocalMessageCleanupScreen(),
                          ),
                        ),
                      ),
                      LoomSettingsRow(
                        icon: LoomIcons.science_outlined,
                        title: tr(
                          context,
                          'Radio diagnostics',
                          'عیب‌یابی رادیویی',
                        ),
                        showDivider: false,
                        onTap: () => Navigator.pushNamed(
                          context,
                          '/settings/nearby-diagnostics',
                        ),
                      ),
                    ],
                  ),
                )),
                const SizedBox(height: LoomSpacing.lg),
                _entranceWrap(sectionIndex[4], _debugSection(
                  context,
                  debugSnapshot,
                )),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _statusHero(BuildContext context, bool active, String status) {
    final reduceMotion = LoomAccessibility.fromContext(context).reduceMotion;
    return LoomSettingsCard(
      padding: const EdgeInsets.all(LoomSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AnimatedContainer(
                duration: reduceMotion ? Duration.zero : LoomMotion.component,
                curve: LoomMotion.standard,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: (active ? context.loom.connectivity : context.loom.textMuted)
                      .withValues(alpha: .16),
                ),
                child: Icon(
                  active
                      ? LoomIcons.wifi_tethering_rounded
                      : LoomIcons.near_me_outlined,
                  color: active
                      ? context.loom.connectivity
                      : context.loom.textMuted,
                ),
              ),
              const SizedBox(width: LoomSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tr(context, 'Offline DTN mode', 'حالت DTN آفلاین'),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 2),
                    AnimatedSwitcher(
                      duration: reduceMotion
                          ? Duration.zero
                          : LoomMotion.component,
                      child: Text(
                        status,
                        key: ValueKey(status),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: active
                              ? context.loom.connectivity
                              : context.loom.textSecondary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Switch.adaptive(
                value: active,
                onChanged: _busy
                    ? null
                    : (value) {
                        if (value) {
                          unawaited(widget.controller.enable());
                        } else {
                          unawaited(widget.controller.disable());
                        }
                      },
              ),
            ],
          ),
          const SizedBox(height: LoomSpacing.md),
          Text(
            tr(
              context,
              'When enabled, Loom keeps a user-visible Nearby foreground lifetime and exchanges opaque DTN packets over supported Bluetooth LE, Wi-Fi Direct and Wi-Fi Aware links. Relay peers never receive message plaintext or account identifiers from discovery beacons.',
              'وقتی فعال باشد، لوم یک سرویس قابل‌مشاهده Nearby نگه می‌دارد و بسته‌های رمز‌شده DTN را از مسیرهای پشتیبانی‌شده Bluetooth LE، Wi-Fi Direct و Wi-Fi Aware جابه‌جا می‌کند. همتاهای رله متن پیام یا شناسه حساب را از اعلان‌های کشف دریافت نمی‌کنند.',
            ),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: context.loom.textSecondary,
              height: 1.5,
            ),
          ),
          if (widget.controller.errorMessage != null &&
              widget.controller.errorMessage!.isNotEmpty) ...[
            const SizedBox(height: LoomSpacing.sm),
            Text(
              widget.controller.status == LoomNearbyDtnServiceStatus.active
                  ? tr(
                      context,
                      'Optional bearer error: ${widget.controller.errorMessage}',
                      'خطای یکی از مسیرهای اختیاری: ${widget.controller.errorMessage}',
                    )
                  : widget.controller.errorMessage!,
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _roundStat(BuildContext context, String value, String label) {
    final theme = Theme.of(context);
    return Expanded(
      child: Column(
        children: [
          Text(
            value,
            style: theme.textTheme.titleLarge?.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()],
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            textAlign: TextAlign.center,
            style: theme.bodySmall?.copyWith(
              color: context.loom.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _section(
    BuildContext context, {
    required String title,
    required Widget child,
    String? detail,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.only(
          left: LoomSpacing.sm,
          right: LoomSpacing.sm,
          bottom: LoomSpacing.sm,
        ),
        child: Text(title, style: Theme.of(context).textTheme.titleMedium),
      ),
      if (detail != null)
        Padding(
          padding: const EdgeInsets.only(
            left: LoomSpacing.sm,
            right: LoomSpacing.sm,
            bottom: LoomSpacing.sm,
          ),
          child: Text(
            detail,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: context.loom.textSecondary,
            ),
          ),
        ),
      child,
    ],
  );

  Widget _debugSection(BuildContext context, String debugSnapshot) {
    return _section(
      context,
      title: tr(context, 'Debug snapshot', 'خلاصه دیباگ'),
      detail: tr(
        context,
        'Safe to share: no message text, keys, tokens, SSID, IP address or account identifiers are included.',
        'برای اشتراک امن است: متن پیام، کلید، توکن، SSID، IP یا شناسه حساب داخلش نیست.',
      ),
      child: LoomSettingsGroup(
        children: [
          Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              tilePadding: const EdgeInsets.symmetric(
                horizontal: LoomSpacing.md,
              ),
              childrenPadding: const EdgeInsets.fromLTRB(
                LoomSpacing.md,
                0,
                LoomSpacing.md,
                LoomSpacing.md,
              ),
              title: Text(
                tr(context, 'Show raw snapshot', 'نمایش خروجی خام'),
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              children: [
                SelectableText(
                  debugSnapshot,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: LoomSpacing.sm),
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: OutlinedButton(
                    onPressed: () async {
                      await Clipboard.setData(
                        ClipboardData(text: debugSnapshot),
                      );
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            tr(
                              context,
                              'Nearby debug info copied.',
                              'اطلاعات دیباگ Nearby کپی شد.',
                            ),
                          ),
                        ),
                      );
                    },
                    child: Text(
                      tr(context, 'Copy debug info', 'کپی اطلاعات دیباگ'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _debugSnapshot() {
    final controller = widget.controller;
    final network = LoomDefaultNetworkGeneration.current;
    final round = controller.lastRound;
    final supported = controller.supportedBearers.isEmpty
        ? 'none'
        : controller.supportedBearers.map((value) => value.name).join(',');
    final foreground = controller.foregroundBearer?.name ?? 'none';
    final error = controller.errorMessage?.trim();
    return <String>[
      'loom-nearby-snapshot-v3',
      'capturedAt=${DateTime.now().toUtc().toIso8601String()}',
      'serviceStatus=${controller.status.name}',
      'enabled=${controller.enabled}',
      'foregroundBearer=$foreground',
      'supportedBearers=$supported',
      'networkGeneration=${network.generation}',
      'networkTransport=${network.transportClass}',
      'networkValidated=${network.validated}',
      'roundDiscovered=${round?.discoveredCandidates ?? -1}',
      'roundConnectedOutbound=${round?.connectedCandidates ?? -1}',
      'roundOutboundAck=${round?.outboundPacketsAccepted ?? -1}',
      'roundInboundAccepted=${round?.inboundPacketsAccepted ?? -1}',
      'roundFailures=${round?.failedEncounters ?? -1}',
      'custodyCalls=${LoomLegacyDtnCustodyDiagnostics.persistCalls}',
      'custodySuccess=${LoomLegacyDtnCustodyDiagnostics.successfulCalls}',
      'custodyFailed=${LoomLegacyDtnCustodyDiagnostics.failedCalls}',
      'custodyNewPackets=${LoomLegacyDtnCustodyDiagnostics.newPackets}',
      'custodyReusedPackets=${LoomLegacyDtnCustodyDiagnostics.reusedPackets}',
      'custodyLastPacketCount=${LoomLegacyDtnCustodyDiagnostics.lastPacketCount}',
      'custodyLastResult=${LoomLegacyDtnCustodyDiagnostics.lastResult}',
      'custodyLastException=${LoomLegacyDtnCustodyDiagnostics.lastExceptionType ?? 'none'}',
      'acceptedMirrorLast=${LoomAcceptedSendDtnDiagnostics.lastResult}',
      'acceptedMirrorPersisted=${LoomAcceptedSendDtnDiagnostics.persistedCount}',
      'acceptedMirrorDirectoryUnavailable=${LoomAcceptedSendDtnDiagnostics.directoryUnavailableCount}',
      'acceptedMirrorFailed=${LoomAcceptedSendDtnDiagnostics.failedCount}',
      'acceptedMirrorException=${LoomAcceptedSendDtnDiagnostics.lastExceptionType ?? 'none'}',
      'acceptedMirrorUpdatedAt=${LoomAcceptedSendDtnDiagnostics.lastUpdatedAt?.toIso8601String() ?? 'none'}',
      'lastError=${error == null || error.isEmpty ? 'none' : error}',
    ].join('\n');
  }

  bool get _busy =>
      widget.controller.status == LoomNearbyDtnServiceStatus.starting ||
      widget.controller.status == LoomNearbyDtnServiceStatus.stopping;

  static String _statusLabel(
    BuildContext context,
    LoomNearbyDtnServiceStatus status,
  ) => switch (status) {
    LoomNearbyDtnServiceStatus.off => tr(context, 'Off', 'خاموش'),
    LoomNearbyDtnServiceStatus.starting => tr(
      context,
      'Starting…',
      'در حال راه‌اندازی…',
    ),
    LoomNearbyDtnServiceStatus.active => tr(context, 'Active', 'فعال'),
    LoomNearbyDtnServiceStatus.stopping => tr(
      context,
      'Stopping…',
      'در حال توقف…',
    ),
    LoomNearbyDtnServiceStatus.unsupported => tr(
      context,
      'No supported native radio',
      'رادیوی بومی پشتیبانی‌شده وجود ندارد',
    ),
    LoomNearbyDtnServiceStatus.permissionDenied => tr(
      context,
      'Permission denied',
      'مجوز رد شد',
    ),
    LoomNearbyDtnServiceStatus.error => tr(context, 'Error', 'خطا'),
  };

  static String _bearerLabel(LoomNearbyBearer bearer) => switch (bearer) {
    LoomNearbyBearer.bluetoothLowEnergy => 'Bluetooth LE',
    LoomNearbyBearer.wifiDirect => 'Wi-Fi Direct',
    LoomNearbyBearer.wifiAware => 'Wi-Fi Aware',
    LoomNearbyBearer.multipeer => 'Multipeer',
    LoomNearbyBearer.localPeer => 'Local peer',
  };
}
