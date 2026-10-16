import 'package:loom_design/loom_design.dart';
import 'package:loom_protocol/loom_protocol.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../app/loom_strings.dart';
import '../../media/application/media_capabilities.dart';

/// Scans the public QR emitted by [LoomProfileQrScreen].
///
/// Profile QR codes intentionally contain only a canonical Loom address.
/// This screen validates that address locally before returning it to the People
/// flow, where the existing Home-Node identity/device resolution remains the
/// authority before a contact can be saved.
class LoomContactQrScannerScreen extends StatefulWidget {
  const LoomContactQrScannerScreen({super.key});

  @override
  State<LoomContactQrScannerScreen> createState() =>
      _LoomContactQrScannerScreenState();
}

class _LoomContactQrScannerScreenState
    extends State<LoomContactQrScannerScreen> {
  late final MobileScannerController? _scanner =
      LoomMediaCapabilities.cameraCapture
      ? MobileScannerController(
          formats: const <BarcodeFormat>[BarcodeFormat.qrCode],
          detectionSpeed: DetectionSpeed.noDuplicates,
        )
      : null;

  bool _handled = false;
  String? _errorMessage;

  @override
  void dispose() {
    _scanner?.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled || !mounted) return;

    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue?.trim();
      if (raw == null || raw.isEmpty) continue;
      try {
        final address = LoomAddress.parseCanonical(raw).canonical;
        _handled = true;
        Navigator.of(context).pop(address);
        return;
      } on FormatException {
        if (_errorMessage == null) {
          setState(() {
            _errorMessage = tr(
              context,
              'This QR is not a valid Loom profile address.',
              'این QR یک نشانی معتبر پروفایل لوم نیست.',
            );
          });
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!LoomMediaCapabilities.cameraCapture) {
      return Scaffold(
        appBar: LoomGlassAppBar(
          title: Text(tr(context, 'Contact address', 'نشانی مخاطب')),
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  tr(
                    context,
                    'QR camera scanning is unavailable on this platform. Enter the contact address in People.',
                    'اسکن QR با دوربین روی این پلتفرم در دسترس نیست. نشانی مخاطب را در بخش افراد وارد کنید.',
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(tr(context, 'Back to People', 'بازگشت به افراد')),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: LoomGlassAppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        title: Text(tr(context, 'Scan contact QR', 'اسکن QR مخاطب')),
      ),
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            MobileScanner(controller: _scanner, onDetect: _onDetect),
            IgnorePointer(
              child: Center(
                child: Container(
                  width: 244,
                  height: 244,
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: Theme.of(context).colorScheme.primary,
                      width: 3,
                    ),
                    borderRadius: BorderRadius.circular(28),
                  ),
                ),
              ),
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.all(LoomSpacing.md),
                child: LoomGlassSurface(
                  strength: LoomGlassStrength.strong,
                  padding: const EdgeInsets.all(LoomSpacing.md),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        tr(
                          context,
                          'Point the camera at a Loom Profile QR. The scanned address will be cryptographically resolved before you can save the contact.',
                          'دوربین را روی QR پروفایل لوم بگیرید. پیش از ذخیره مخاطب، هویت نشانی اسکن‌شده به‌صورت رمزنگاری‌شده بررسی می‌شود.',
                        ),
                        textAlign: TextAlign.center,
                      ),
                      if (_errorMessage != null) ...[
                        const SizedBox(height: LoomSpacing.sm),
                        Text(
                          _errorMessage!,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
