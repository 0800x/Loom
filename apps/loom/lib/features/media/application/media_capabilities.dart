import 'package:flutter/foundation.dart';

/// Capabilities of the capture plugins actually registered by this app.
/// The current camera dependency has no Windows capture implementation.
abstract final class LoomMediaCapabilities {
  static bool cameraCaptureFor(TargetPlatform platform) =>
      platform == TargetPlatform.android || platform == TargetPlatform.iOS;
  static bool get cameraCapture =>
      !kIsWeb && cameraCaptureFor(defaultTargetPlatform);
  static bool get photoLibrary => cameraCapture;
}
