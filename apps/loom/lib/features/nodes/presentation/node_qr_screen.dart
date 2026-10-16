import 'dart:io';
import 'package:loom_design/loom_design.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../../../app/loom_strings.dart';
import '../application/node_share_link.dart';
import '../application/node_directory_controller.dart';
import '../../onboarding/application/onboarding_controller.dart';

Future<void> scanLoomNode(
  BuildContext context,
  LoomNodeDirectoryController controller,
) async {
  final raw = await Navigator.push<String>(
    context,
    MaterialPageRoute(builder: (_) => const LoomNodeQrScanner()),
  );
  if (raw == null || !context.mounted) return;
  try {
    final link = LoomNodeShareLink.parse(raw);
    if (LoomOnboardingScope.of(context).receipt != null &&
        link.endpoint.authority.toLowerCase() !=
            controller.selectedEndpoint?.authority.toLowerCase()) {
      throw StateError('Cannot change an authenticated account Home Node');
    }
    await controller.discoverAndSelectDomain(
      link.endpoint.authority,
      expectedNodeId: link.nodeId,
      expectedFingerprint: link.fingerprint,
    );
    if (!context.mounted) return;
    if (controller.errorMessage != null) {
      throw StateError(controller.errorMessage!);
    }
    await Navigator.pushNamed(context, '/node-detail');
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            tr(
              context,
              'Could not verify this server QR. Check the link and connection.',
              'تأیید QR سرور ممکن نشد؛ لینک و اتصال را بررسی کنید.',
            ),
          ),
        ),
      );
    }
  }
}

class LoomNodeShareScreen extends StatelessWidget {
  const LoomNodeShareScreen({required this.link, super.key});
  final LoomNodeShareLink link;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: LoomGlassAppBar(title: Text(tr(context, 'Share server', 'اشتراک سرور'))),
    body: Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              link.endpoint.authority,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
              ),
              child: QrImageView(
                data: link.encoded,
                size: 240,
                backgroundColor: Colors.white,
                eyeStyle: const QrEyeStyle(
                  eyeShape: QrEyeShape.square,
                  color: Colors.black,
                ),
                dataModuleStyle: const QrDataModuleStyle(
                  dataModuleShape: QrDataModuleShape.square,
                  color: Colors.black,
                ),
              ),
            ),
            const SizedBox(height: 20),
            SelectableText(link.encoded, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: link.encoded));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        tr(
                          context,
                          'Connection link copied',
                          'لینک اتصال کپی شد',
                        ),
                      ),
                    ),
                  );
                }
              },
              icon: const Icon(LoomIcons.copy_outlined),
              label: Text(
                tr(context, 'Copy connection link', 'کپی لینک اتصال'),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              tr(
                context,
                'Scan with Add server → Scan QR. The live server identity is checked before selection.',
                'در افزودن سرور، QR را اسکن کنید. هویت زندهٔ سرور پیش از انتخاب بررسی می‌شود.',
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    ),
  );
}

class LoomNodeQrScanner extends StatefulWidget {
  const LoomNodeQrScanner({super.key});
  @override
  State<LoomNodeQrScanner> createState() => _NodeScannerState();
}

class _NodeScannerState extends State<LoomNodeQrScanner>
    with WidgetsBindingObserver {
  final scanner = MobileScannerController();
  final text = TextEditingController();
  bool _returned = false;
  bool get supported =>
      Platform.isAndroid || Platform.isIOS || Platform.isMacOS;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!supported || _returned) return;
    unawaited(
      (state == AppLifecycleState.resumed ? scanner.start() : scanner.stop())
          .catchError((Object _) {}),
    );
  }

  void accept(String raw) {
    if (_returned) return;
    try {
      LoomNodeShareLink.parse(raw);
      _returned = true;
      unawaited(scanner.stop().catchError((Object _) {}));
      Navigator.pop(context, raw);
    } catch (_) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            tr(context, 'Not a valid server QR', 'QR سرور معتبر نیست'),
          ),
        ),
      );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    scanner.dispose();
    text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: LoomGlassAppBar(title: Text(tr(context, 'Scan server QR', 'اسکن QR سرور'))),
    body: Column(
      children: [
        if (supported)
          Expanded(
            child: MobileScanner(
              controller: scanner,
              onDetect: (capture) {
                for (final code in capture.barcodes) {
                  final raw = code.rawValue;
                  if (raw != null) {
                    try {
                      LoomNodeShareLink.parse(raw);
                      accept(raw);
                      return;
                    } catch (_) {}
                  }
                }
              },
              errorBuilder: (_, error) => Center(
                child: Text(
                  tr(
                    context,
                    'Camera unavailable. Paste the connection link below.',
                    'دوربین در دسترس نیست؛ لینک اتصال را وارد کنید.',
                  ),
                ),
              ),
            ),
          )
        else
          const Spacer(),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: text,
                    decoration: InputDecoration(
                      hintText: tr(
                        context,
                        'Paste connection link',
                        'لینک اتصال را وارد کنید',
                      ),
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () => accept(text.text),
                  icon: const Icon(LoomIcons.arrow_forward_rounded),
                ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}

