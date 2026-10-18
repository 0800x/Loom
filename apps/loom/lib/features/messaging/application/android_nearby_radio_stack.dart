import 'package:loom_transport/loom_transport.dart';

import 'android_ble_radio_adapter.dart';
import 'android_wifi_aware_radio_adapter.dart';
import 'android_wifi_direct_radio_adapter.dart';

typedef LoomNearbyPermissionRequester =
    Future<bool> Function(LoomNearbyBearer bearer);

/// Product permission policy for heterogeneous Nearby bearers.
///
/// Android devices commonly expose several nearby transports while the user has
/// only granted one of their permission groups. A denied or temporarily broken
/// bearer must not disable another already-authorized transport such as BLE.
final class LoomNearbyPermissionPolicy {
  const LoomNearbyPermissionPolicy._();

  static Future<bool> requestAtLeastOne({
    required Iterable<LoomNearbyBearer> bearers,
    required LoomNearbyPermissionRequester request,
  }) async {
    var grantedAny = false;
    for (final bearer in bearers) {
      try {
        if (await request(bearer)) grantedAny = true;
      } catch (_) {
        // Keep probing the remaining independent bearers. Startup only fails
        // when none of the requested transports can be authorized.
      }
    }
    return grantedAny;
  }
}

/// Capability-aware Android nearby radio registry.
///
/// It does not authenticate peers. It only selects a raw bearer; all returned
/// links still pass through the Loom peer-security layer before DTN use.
final class LoomAndroidNearbyRadioStack {
  LoomAndroidNearbyRadioStack({
    LoomAndroidBleRadioAdapter? ble,
    LoomAndroidWifiAwareRadioAdapter? wifiAware,
    LoomAndroidWifiDirectRadioAdapter? wifiDirect,
  }) : ble = ble ?? LoomAndroidBleRadioAdapter(),
       wifiAware = wifiAware ?? LoomAndroidWifiAwareRadioAdapter(),
       wifiDirect = wifiDirect ?? LoomAndroidWifiDirectRadioAdapter();

  final LoomAndroidBleRadioAdapter ble;
  final LoomAndroidWifiAwareRadioAdapter wifiAware;
  final LoomAndroidWifiDirectRadioAdapter wifiDirect;

  Future<Set<LoomNearbyBearer>> supportedBearers() async {
    final supported = <LoomNearbyBearer>{};
    if (await ble.isSupported()) {
      supported.add(LoomNearbyBearer.bluetoothLowEnergy);
    }
    if (await wifiAware.isSupported()) {
      supported.add(LoomNearbyBearer.wifiAware);
    }
    if (await wifiDirect.isSupported()) {
      supported.add(LoomNearbyBearer.wifiDirect);
    }
    return Set.unmodifiable(supported);
  }

  LoomNearbyRadioAdapter adapterFor(LoomNearbyBearer bearer) =>
      switch (bearer) {
        LoomNearbyBearer.bluetoothLowEnergy => ble,
        LoomNearbyBearer.wifiAware => wifiAware,
        LoomNearbyBearer.wifiDirect => wifiDirect,
        LoomNearbyBearer.multipeer ||
        LoomNearbyBearer.localPeer => throw UnsupportedError(
          'Bearer $bearer is not an Android native radio',
        ),
      };

  Future<bool> requestPermissionsFor(Set<LoomNearbyBearer> bearers) =>
      LoomNearbyPermissionPolicy.requestAtLeastOne(
        bearers: bearers,
        request: (bearer) => switch (bearer) {
          LoomNearbyBearer.bluetoothLowEnergy => ble.requestPermissions(),
          LoomNearbyBearer.wifiAware => wifiAware.requestPermissions(),
          LoomNearbyBearer.wifiDirect => wifiDirect.requestPermissions(),
          LoomNearbyBearer.multipeer ||
          LoomNearbyBearer.localPeer => Future<bool>.value(true),
        },
      );

  Future<void> startForegroundMode(LoomNearbyBearer bearer) => switch (bearer) {
    LoomNearbyBearer.bluetoothLowEnergy => ble.startForegroundMode(),
    LoomNearbyBearer.wifiAware => wifiAware.startForegroundMode(),
    LoomNearbyBearer.wifiDirect => wifiDirect.startForegroundMode(),
    LoomNearbyBearer.multipeer ||
    LoomNearbyBearer.localPeer => Future<void>.error(
      UnsupportedError('Bearer $bearer has no Android foreground radio'),
    ),
  };

  Future<void> stopForegroundMode() async {
    // All three adapters target the same NearbyForegroundService. Stopping one
    // stops the shared user-visible nearby lifetime.
    await ble.stopForegroundMode();
  }
}
