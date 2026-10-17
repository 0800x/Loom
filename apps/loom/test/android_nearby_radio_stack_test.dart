import 'package:loom_next/features/messaging/application/android_ble_radio_adapter.dart';
import 'package:loom_next/features/messaging/application/android_nearby_radio_stack.dart';
import 'package:loom_next/features/messaging/application/android_wifi_readiness_policy.dart';
import 'package:loom_transport/loom_transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Nearby remains usable when only BLE permission is granted', () async {
    final attempted = <LoomNearbyBearer>[];
    const bearers = <LoomNearbyBearer>{
      LoomNearbyBearer.wifiAware,
      LoomNearbyBearer.wifiDirect,
      LoomNearbyBearer.bluetoothLowEnergy,
    };

    final granted = await LoomNearbyPermissionPolicy.requestAtLeastOne(
      bearers: bearers,
      request: (bearer) async {
        attempted.add(bearer);
        return bearer == LoomNearbyBearer.bluetoothLowEnergy;
      },
    );

    expect(granted, isTrue);
    expect(attempted.toSet(), bearers);
  });

  test('one bearer failure does not prevent a later usable bearer', () async {
    final attempted = <LoomNearbyBearer>[];

    final granted = await LoomNearbyPermissionPolicy.requestAtLeastOne(
      bearers: const <LoomNearbyBearer>[
        LoomNearbyBearer.wifiAware,
        LoomNearbyBearer.bluetoothLowEnergy,
      ],
      request: (bearer) async {
        attempted.add(bearer);
        if (bearer == LoomNearbyBearer.wifiAware) {
          throw StateError('Wi-Fi permission flow unavailable');
        }
        return true;
      },
    );

    expect(granted, isTrue);
    expect(
      attempted,
      const <LoomNearbyBearer>[
        LoomNearbyBearer.wifiAware,
        LoomNearbyBearer.bluetoothLowEnergy,
      ],
    );
  });

  test('Nearby permission startup fails when no bearer is usable', () async {
    final granted = await LoomNearbyPermissionPolicy.requestAtLeastOne(
      bearers: const <LoomNearbyBearer>[
        LoomNearbyBearer.wifiAware,
        LoomNearbyBearer.wifiDirect,
        LoomNearbyBearer.bluetoothLowEnergy,
      ],
      request: (_) async => false,
    );

    expect(granted, isFalse);
  });

  test('BLE radio enable consent continues automatically after permission', () async {
    final steps = <String>[];

    final ready = await LoomAndroidBleReadinessPolicy.request(
      requestPermissions: () async {
        steps.add('permission');
        return true;
      },
      ensureRadioReady: () async {
        steps.add('radio');
        return true;
      },
    );

    expect(ready, isTrue);
    expect(steps, const <String>['permission', 'radio']);
  });

  test('BLE radio enable flow is not launched when permission is denied', () async {
    var radioRequested = false;

    final ready = await LoomAndroidBleReadinessPolicy.request(
      requestPermissions: () async => false,
      ensureRadioReady: () async {
        radioRequested = true;
        return true;
      },
    );

    expect(ready, isFalse);
    expect(radioRequested, isFalse);
  });

  test('Wi-Fi settings flow continues automatically after permission', () async {
    final steps = <String>[];

    final ready = await LoomAndroidWifiReadinessPolicy.request(
      requestPermissions: () async {
        steps.add('permission');
        return true;
      },
      ensureRadioReady: () async {
        steps.add('settings');
        return true;
      },
    );

    expect(ready, isTrue);
    expect(steps, const <String>['permission', 'settings']);
  });

  test('Wi-Fi settings flow is skipped when Nearby Wi-Fi is denied', () async {
    var settingsRequested = false;

    final ready = await LoomAndroidWifiReadinessPolicy.request(
      requestPermissions: () async => false,
      ensureRadioReady: () async {
        settingsRequested = true;
        return true;
      },
    );

    expect(ready, isFalse);
    expect(settingsRequested, isFalse);
  });
}
