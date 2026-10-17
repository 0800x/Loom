import 'dart:io';

import 'package:loom_crypto_bridge/loom_crypto_bridge.dart';
import 'package:loom_models/loom_models.dart';
import 'package:loom_storage/loom_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

class LoomSecurityController extends ChangeNotifier {
  LoomSecurityController({
    LoomIdentityCore? identityCore,
    LoomDeviceSecurityCore? deviceCore,
    LoomVerificationService? verification,
  })  : _identityCore = identityCore ?? LoomIdentityCoreV1(),
        _deviceCore = deviceCore ?? LoomDeviceSecurityCoreV1(),
        _verification = verification ?? LoomVerificationService();

  final LoomIdentityCore _identityCore;
  final LoomDeviceSecurityCore _deviceCore;
  final LoomVerificationService _verification;

  bool loading = false;
  String? error;
  LoomIdentityPublic? identity;
  LoomDeviceKeyBundle? localDevice;
  LoomDeviceTrustState? localTrust;
  bool? fingerprintValid;
  bool? selfSignatureValid;
  bool? identityBindingValid;
  List<LoomSecurityEvent> recentEvents = const <LoomSecurityEvent>[];
  LoomSecurityStore? _store;

  Future<void> load({String? deviceId}) async {
    loading = true;
    error = null;
    notifyListeners();
    try {
      identity = await _identityCore.readIdentity();
      final currentIdentity = identity;
      if (currentIdentity == null) {
        localDevice = null;
        localTrust = null;
        recentEvents = const <LoomSecurityEvent>[];
        return;
      }
      final directory = await getApplicationSupportDirectory();
      _store ??= LoomSecurityStore.openFile(
        '${directory.path}${Platform.pathSeparator}loom_security.sqlite3',
      );
      if (deviceId != null && deviceId.trim().isNotEmpty) {
        final bundle = await _deviceCore.createOrLoadDevice(
          identity: currentIdentity,
          deviceId: deviceId,
          deviceName: 'Loom ${Platform.operatingSystem}',
          identitySigner: _identityCore,
        );
        localDevice = bundle;
        fingerprintValid = await _verification.verifyFingerprint(bundle);
        selfSignatureValid = await _verification.verifyDeviceSelfSignature(
          bundle,
        );
        identityBindingValid = await _verification.verifyIdentityBinding(
          bundle: bundle,
          identity: currentIdentity,
        );
        if (fingerprintValid != true ||
            selfSignatureValid != true ||
            identityBindingValid != true) {
          throw StateError(
            'Local device key bundle failed cryptographic validation',
          );
        }
        localTrust = _store!.observeDevice(
          bundle,
          observedAt: DateTime.now().toUtc(),
        );
        _store!.addEvent(
          LoomSecurityEvent(
            eventId: 'local-device:${bundle.deviceId}:${bundle.fingerprint}',
            kind: LoomSecurityEventKind.deviceAdded,
            identityId: bundle.identityId,
            deviceId: bundle.deviceId,
            createdAt: bundle.createdAt,
            summary: 'Local device key bundle created or observed.',
          ),
        );
      } else {
        localDevice = null;
        localTrust = null;
        fingerprintValid = null;
        selfSignatureValid = null;
        identityBindingValid = null;
      }
      recentEvents = _store!.listEvents(limit: 20);
    } catch (exception) {
      error = exception.toString();
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _store?.close();
    super.dispose();
  }
}
