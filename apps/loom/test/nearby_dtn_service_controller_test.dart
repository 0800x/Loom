import 'dart:async';
import 'dart:typed_data';

import 'package:loom_models/loom_models.dart';
import 'package:loom_next/features/messaging/application/nearby_dtn_service_controller.dart';
import 'package:loom_next/features/nodes/application/node_directory_controller.dart';
import 'package:loom_next/features/onboarding/application/onboarding_controller.dart';
import 'package:loom_transport/loom_transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Nearby DTN mode refuses to start without a registered device', () async {
    final nodes = LoomNodeDirectoryController();
    final onboarding = LoomOnboardingController(nodes: nodes);
    var runtimeFactoryCalls = 0;
    final controller = LoomNearbyDtnServiceController(
      onboarding: onboarding,
      runtimeFactory: (path) {
        runtimeFactoryCalls++;
        throw StateError('runtime must not open');
      },
      supportPathProvider: () async => '/unused',
    );
    addTearDown(controller.dispose);
    addTearDown(onboarding.dispose);
    addTearDown(nodes.dispose);

    expect(await controller.enable(), isFalse);
    expect(controller.enabled, isFalse);
    expect(controller.status, LoomNearbyDtnServiceStatus.error);
    expect(runtimeFactoryCalls, 0);
    expect(controller.errorMessage, contains('registered Loom device'));
  });

  test('Nearby DTN auto recovery retries only transient errors', () {
    expect(
      LoomNearbyDtnServiceController.shouldAutoRecover(
        LoomNearbyDtnServiceStatus.error,
      ),
      isTrue,
    );
    for (final status in <LoomNearbyDtnServiceStatus>[
      LoomNearbyDtnServiceStatus.off,
      LoomNearbyDtnServiceStatus.starting,
      LoomNearbyDtnServiceStatus.active,
      LoomNearbyDtnServiceStatus.stopping,
      LoomNearbyDtnServiceStatus.unsupported,
      LoomNearbyDtnServiceStatus.permissionDenied,
    ]) {
      expect(
        LoomNearbyDtnServiceController.shouldAutoRecover(status),
        isFalse,
        reason: '${status.name} must not silently restart Nearby DTN',
      );
    }
  });

  test('Test E - stale enable completion cannot reactivate after disable',
      () async {
    final harness = _Harness();
    addTearDown(harness.dispose);
    final supported = Completer<Set<LoomNearbyBearer>>();
    harness.runtime.supportedFuture = supported.future;

    final enabling = harness.controller.enable();
    await harness.runtime.supportedCalled.future;
    final disabling = harness.controller.disable();
    supported.complete(<LoomNearbyBearer>{
      LoomNearbyBearer.bluetoothLowEnergy,
    });

    expect(await enabling, isFalse);
    await disabling;
    expect(harness.controller.enabled, isFalse);
    expect(harness.controller.status, LoomNearbyDtnServiceStatus.off);
    expect(harness.runtime.startForegroundCalls, 0);
  });

  test('Test D - network restoration kicks uplink while Nearby stays active',
      () async {
    final harness = _Harness(active: true);
    addTearDown(harness.dispose);
    expect(await harness.controller.enable(), isTrue);
    final before = harness.runtime.uplinkKicks;

    LoomDefaultNetworkGeneration.advance(
      transportClass: 'wifi',
      validated: true,
    );
    await Future<void>.delayed(Duration.zero);

    expect(harness.controller.enabled, isTrue);
    expect(harness.controller.status, LoomNearbyDtnServiceStatus.active);
    expect(harness.runtime.uplinkKicks, greaterThan(before));
  });

  test('Test F - online carrier keeps Nearby scan/carry lifecycle enabled',
      () async {
    final harness = _Harness(active: true);
    addTearDown(harness.dispose);
    expect(await harness.controller.enable(), isTrue);

    LoomDefaultNetworkGeneration.advance(
      transportClass: 'cellular',
      validated: true,
    );
    await Future<void>.delayed(Duration.zero);

    expect(harness.controller.enabled, isTrue);
    expect(harness.runtime.stopForegroundCalls, 0);
    expect(harness.runtime.closed, isFalse);
  });
}

final class _Harness {
  _Harness({bool active = false}) {
    onboarding.committedIdentity = LoomIdentityPublic(
      identityId: 'identity-test-0001',
      publicKey: 'identity-public-key',
      fingerprint: 'identity-fingerprint',
      createdAt: DateTime.utc(2026, 9, 15),
    );
    onboarding.receipt = const LoomRegistrationReceipt(
      accountId: 'account-test-0001',
      deviceId: 'device-test-0001',
      address: 'tester@node.example',
      homeNode: 'node.example',
    );
    runtime = _FakeRuntime();
    if (active) {
      runtime.supportedFuture = Future<Set<LoomNearbyBearer>>.value(
        <LoomNearbyBearer>{LoomNearbyBearer.bluetoothLowEnergy},
      );
    }
    controller = LoomNearbyDtnServiceController(
      onboarding: onboarding,
      runtimeFactory: (_) => runtime,
      signerFactory: (_, __) async => const _Signer(),
      roundExecutor: ({required runtime, required signer, required bearer}) =>
          this.runtime.roundBlocker.future,
      messageGatewayRoundExecutor: ({
        required runtime,
        required signer,
        required bearer,
        required gateway,
      }) async => 0,
      supportPathProvider: () async => '/unused',
      roundPause: const Duration(days: 1),
    );
  }

  final LoomNodeDirectoryController nodes = LoomNodeDirectoryController();
  late final LoomOnboardingController onboarding =
      LoomOnboardingController(nodes: nodes);
  late final _FakeRuntime runtime;
  late final LoomNearbyDtnServiceController controller;

  void dispose() {
    controller.dispose();
    if (!runtime.roundBlocker.isCompleted) {
      runtime.roundBlocker.complete(const LoomNearbyDtnRoundResult(
        discoveredCandidates: 0,
        connectedCandidates: 0,
        inboundPacketsAccepted: 0,
        outboundPacketsAccepted: 0,
        failedEncounters: 0,
      ));
    }
    onboarding.dispose();
    nodes.dispose();
  }
}

final class _FakeRuntime implements LoomNearbyDtnRuntimePort {
  Future<Set<LoomNearbyBearer>> supportedFuture =
      Completer<Set<LoomNearbyBearer>>().future;
  final Completer<void> supportedCalled = Completer<void>();
  final Completer<LoomNearbyDtnRoundResult> roundBlocker =
      Completer<LoomNearbyDtnRoundResult>();
  int startForegroundCalls = 0;
  int stopForegroundCalls = 0;
  int uplinkKicks = 0;
  bool closed = false;

  @override
  LoomNearbyDtnEncounterCoordinator get coordinator =>
      throw UnimplementedError();

  @override
  Future<Set<LoomNearbyBearer>> supportedBearers() {
    if (!supportedCalled.isCompleted) supportedCalled.complete();
    return supportedFuture;
  }

  @override
  Future<bool> requestPermissionsFor(Set<LoomNearbyBearer> bearers) async =>
      true;

  @override
  Future<void> startForegroundMode(LoomNearbyBearer bearer) async {
    startForegroundCalls++;
  }

  @override
  Future<void> stopForegroundMode() async {
    stopForegroundCalls++;
  }

  @override
  LoomNearbyRadioAdapter radioFor(LoomNearbyBearer bearer) =>
      throw UnimplementedError();

  @override
  void kickDestinationNodeUplink(LoomDirectTransportSigner signer) {
    uplinkKicks++;
  }

  @override
  void close() {
    closed = true;
  }
}

final class _Signer implements LoomDirectTransportSigner {
  const _Signer();

  @override
  Future<Uint8List> ed25519PublicKey() async =>
      Uint8List.fromList(List<int>.filled(32, 1));

  @override
  Future<Uint8List> sign(Uint8List canonicalBytes) async =>
      Uint8List.fromList(List<int>.filled(64, 2));
}
