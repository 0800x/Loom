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

class LoomNearbyModeScreen extends StatelessWidget {
  const LoomNearbyModeScreen({required this.controller, super.key});

  final LoomNearbyDtnServiceController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final active = controller.enabled;
        final status = _statusLabel(context, controller.status);
        final round = controller.lastRound;
        final debugSnapshot = _debugSnapshot();
        return Scaffold(
          appBar: LoomGlassAppBar(
            title: Text(tr(context, 'Nearby messaging', 'پیام‌رسانی نزدیک')),
          ),
          body: ListView(
            padding: const EdgeInsets.all(LoomSpacing.md),
            children: [
              LoomSettingsCard(
                padding: const EdgeInsets.all(LoomSpacing.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          LoomIcons.near_me_outlined,
                          color: context.loom.primary,
                        ),
                        const SizedBox(width: LoomSpacing.sm),
                        Expanded(
                          child: Text(
                            tr(context, 'Offline DTN mode', 'حالت DTN آفلاین'),
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        Switch.adaptive(
                          value: active,
                          onChanged: _busy
                              ? null
                              : (value) {
                                  if (value) {
                                    unawaited(controller.enable());
                                  } else {
                                    unawaited(controller.disable());
                                  }
                                },
                        ),
                      ],
                    ),
                    const SizedBox(height: LoomSpacing.sm),
                    Text(
                      tr(
                        context,
                        'When enabled, Loom keeps a user-visible Nearby foreground lifetime and exchanges opaque DTN packets over supported Bluetooth LE, Wi-Fi Direct and Wi-Fi Aware links. Relay peers never receive message plaintext or account identifiers from discovery beacons.',
                        'وقتی فعال باشد، لوم یک سرویس قابل‌مشاهده Nearby نگه می‌دارد و بسته‌های رمز‌شده DTN را از مسیرهای پشتیبانی‌شده Bluetooth LE، Wi-Fi Direct و Wi-Fi Aware جابه‌جا می‌کند. همتاهای رله متن پیام یا شناسه حساب را از اعلان‌های کشف دریافت نمی‌کنند.',
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: LoomSpacing.md),
              ListTile(
                leading: const Icon(LoomIcons.info_outline_rounded),
                title: Text(tr(context, 'Status', 'وضعیت')),
                subtitle: Text(status),
              ),
              ListTile(
                leading: const Icon(LoomIcons.bluetooth_disabled),
                title: Text(
                  tr(context, 'Foreground bearer', 'مسیر foreground'),
                ),
                subtitle: Text(
                  controller.foregroundBearer == null
                      ? tr(context, 'None', 'هیچ‌کدام')
                      : _bearerLabel(controller.foregroundBearer!),
                ),
              ),
              ListTile(
                leading: const Icon(LoomIcons.hub_outlined),
                title: Text(
                  tr(context, 'Supported bearers', 'مسیرهای پشتیبانی‌شده'),
                ),
                subtitle: Text(
                  controller.supportedBearers.isEmpty
                      ? tr(context, 'Not probed yet', 'هنوز بررسی نشده')
                      : controller.supportedBearers
                            .map(_bearerLabel)
                            .join(' • '),
                ),
              ),
              if (round != null)
                ListTile(
                  leading: const Icon(LoomIcons.schedule_outlined),
                  title: Text(
                    tr(
                      context,
                      'Last outbound DTN round',
                      'آخرین دور خروجی DTN',
                    ),
                  ),
                  subtitle: Text(
                    tr(
                      context,
                      '${round.discoveredCandidates} discovered, ${round.connectedCandidates} outbound connect(s), ${round.outboundPacketsAccepted} custody ACK(s), ${round.inboundPacketsAccepted} inbound packet(s), ${round.failedEncounters} failed encounter(s)',
                      '${round.discoveredCandidates} کشف، ${round.connectedCandidates} اتصال خروجی، ${round.outboundPacketsAccepted} تأیید custody، ${round.inboundPacketsAccepted} بسته ورودی، ${round.failedEncounters} encounter ناموفق',
                    ),
                  ),
                ),
              if (controller.errorMessage != null &&
                  controller.errorMessage!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: LoomSpacing.md,
                    vertical: LoomSpacing.sm,
                  ),
                  child: Text(
                    controller.status == LoomNearbyDtnServiceStatus.active
                        ? tr(
                            context,
                            'Optional bearer error: ${controller.errorMessage}',
                            'خطای یکی از مسیرهای اختیاری: ${controller.errorMessage}',
                          )
                        : controller.errorMessage!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              const SizedBox(height: LoomSpacing.md),
              LoomSettingsCard(
                padding: const EdgeInsets.all(LoomSpacing.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tr(context, 'Debug snapshot', 'خلاصه دیباگ'),
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: LoomSpacing.xs),
                    Text(
                      tr(
                        context,
                        'Safe to share: no message text, keys, tokens, SSID, IP address or account identifiers are included.',
                        'برای اشتراک امن است: متن پیام، کلید، توکن، SSID، IP یا شناسه حساب داخلش نیست.',
                      ),
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: context.loom.textSecondary),
                    ),
                    const SizedBox(height: LoomSpacing.sm),
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
              const SizedBox(height: LoomSpacing.md),
              OutlinedButton(
                onPressed: () => Navigator.push<void>(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => const LoomLocalMessageCleanupScreen(),
                  ),
                ),
                child: Text(
                  tr(context, 'Local message cleanup', 'پاک‌سازی محلی پیام‌ها'),
                ),
              ),
              const SizedBox(height: LoomSpacing.sm),
              OutlinedButton.icon(
                onPressed: () => Navigator.pushNamed(
                  context,
                  '/settings/nearby-diagnostics',
                ),
                icon: const Icon(LoomIcons.science_outlined),
                label: Text(
                  tr(
                    context,
                    'Open radio diagnostics',
                    'باز کردن عیب‌یابی رادیویی',
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  String _debugSnapshot() {
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
      controller.status == LoomNearbyDtnServiceStatus.starting ||
      controller.status == LoomNearbyDtnServiceStatus.stopping;

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
