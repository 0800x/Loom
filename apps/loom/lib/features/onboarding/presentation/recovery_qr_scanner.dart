import 'dart:async';

import 'package:loom_design/loom_design.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../app/loom_strings.dart';
import '../application/recovery_backup.dart';

class LoomRecoveryQrScanner extends StatefulWidget {
  const LoomRecoveryQrScanner({super.key});
  @override
  State<LoomRecoveryQrScanner> createState() => _RecoveryQrScannerState();
}

class _RecoveryQrScannerState extends State<LoomRecoveryQrScanner>
    with WidgetsBindingObserver {
  final scanner = MobileScannerController(autoStart: false);
  bool returned = false;
  String? error;
  bool get supported =>
      kIsWeb ||
      [
        TargetPlatform.android,
        TargetPlatform.iOS,
        TargetPlatform.macOS,
      ].contains(defaultTargetPlatform);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && supported) _start();
    });
  }

  void _start() {
    unawaited(
      scanner.start().catchError((Object _) {
        if (mounted) {
          setState(
            () => error = tr(
              context,
              'Camera unavailable. Import your recovery file instead.',
              'دوربین در دسترس نیست؛ فایل پشتیبان را وارد کن.',
            ),
          );
        }
      }),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!supported || returned) return;
    if (state == AppLifecycleState.resumed) {
      _start();
    } else {
      unawaited(scanner.stop().catchError((Object _) {}));
    }
  }

  void _detect(BarcodeCapture capture) {
    if (returned) return;
    for (final code in capture.barcodes) {
      final raw = code.rawValue;
      if (raw == null) continue;
      try {
        final backup = LoomRecoveryBackup.parse(raw);
        returned = true;
        unawaited(scanner.stop().catchError((Object _) {}));
        // No logging, clipboard, external URL, or automatic authentication.
        Navigator.pop(context, backup.sentence);
        return;
      } catch (_) {
        if (error == null) {
          setState(
            () => error = tr(
              context,
              'This is not a Loom recovery QR. Scan the code on your recovery kit.',
              'این QR بازیابی لوم نیست؛ کد روی برگهٔ پشتیبان را اسکن کن.',
            ),
          );
        }
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(scanner.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: LoomGlassAppBar(
      title: Text(tr(context, 'Scan recovery kit', 'اسکن برگهٔ بازیابی')),
    ),
    body: Column(
      children: [
        Expanded(
          child: supported
              ? MobileScanner(
                  controller: scanner,
                  onDetect: _detect,
                  errorBuilder: (_, __) => Center(
                    child: Text(
                      tr(
                        context,
                        'Camera unavailable. Go back and import your recovery file.',
                        'دوربین در دسترس نیست؛ برگرد و فایل پشتیبان را وارد کن.',
                      ),
                    ),
                  ),
                )
              : Center(
                  child: Text(
                    tr(
                      context,
                      'Use a phone camera, or import the .loom file instead.',
                      'با دوربین گوشی اسکن کن یا فایل .loom را وارد کن.',
                    ),
                  ),
                ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              error ??
                  tr(
                    context,
                    'Point at the QR on your printed Loom recovery kit. It stays on this device.',
                    'دوربین را روبه‌روی QR برگهٔ بازیابی بگیر. اطلاعات روی همین دستگاه پردازش می‌شود.',
                  ),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ],
    ),
  );
}
