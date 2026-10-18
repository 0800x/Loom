import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:loom_dtn/loom_dtn.dart';
import 'package:loom_messaging/loom_messaging.dart';
import 'package:loom_protocol/loom_protocol.dart';
import 'package:loom_sessions/loom_sessions.dart';
import 'package:loom_storage/loom_storage.dart';
import 'package:loom_transport/loom_transport.dart';

import 'android_ble_radio_adapter.dart';
import 'android_nearby_radio_stack.dart';
import 'android_state_protector.dart';

enum LoomV2SendReadiness {
  blockedProviderReview,
  blockedStateProtection,
  providerAndStateProtectionSupplied,
}

/// Flutter composition root for Architecture-v2 durable messaging domains.
final class LoomV2MessagingRuntime {
  LoomV2MessagingRuntime._({
    required this.cryptoStateStore,
    required this.messageStateStore,
    required this.accountRootStore,
    required this.accountSignatureVerifier,
    required this.deviceDirectoryStore,
    required this.packetStore,
    required this.packetRouteStore,
    required this.replicaIntakeStore,
    required this.transferExecutor,
    required this.packetCustodyService,
    required this.nearbyDtnEncounters,
    required this.nearbyRadios,
    required this.stateProtector,
    required this.sessionProvider,
    required this.outgoingCoordinator,
    required this._destinationNodeDiscovery,
    required this._destinationNodePoster,
    required this._ownsDestinationNodePoster,
  });

  final LoomCryptoStateStore cryptoStateStore;
  final LoomV2MessageStateStore messageStateStore;

  /// Trust anchors authenticated by account bootstrap/recovery live separately
  /// from server-provided directory snapshots.
  final LoomAccountRootStoreV2 accountRootStore;
  final LoomStoredAccountSignatureVerifierV2 accountSignatureVerifier;
  final LoomDeviceDirectoryStoreV2 deviceDirectoryStore;
  final LoomSqlitePacketStore packetStore;
  final LoomSqlitePacketRouteStore packetRouteStore;
  final LoomSqliteReplicaIntakeStore replicaIntakeStore;
  final LoomDtnTransferExecutor transferExecutor;
  final LoomV2PacketCustodyService packetCustodyService;
  final LoomNearbyDtnEncounterCoordinator nearbyDtnEncounters;
  final LoomAndroidNearbyRadioStack nearbyRadios;
  final LoomSessionStateProtector? stateProtector;
  final LoomSessionCryptoProvider? sessionProvider;
  final LoomV2OutgoingMessageCoordinator? outgoingCoordinator;
  final LoomDestinationNodeDiscovery _destinationNodeDiscovery;
  final LoomDirectHttpPoster _destinationNodePoster;
  final bool _ownsDestinationNodePoster;

  bool _closed = false;
  LoomNearbyBearer? _foregroundBearer;
  LoomDirectTransportSigner? _destinationUplinkSigner;
  Future<void>? _destinationUplinkDrain;
  bool _destinationUplinkKickPending = false;

  static LoomV2MessagingRuntime open({
    required String applicationSupportPath,
    LoomSessionCryptoProvider? reviewedSessionProvider,
    LoomSessionStateProtector? stateProtector,
    LoomAndroidNearbyRadioStack? nearbyRadios,
    LoomAndroidBleRadioAdapter? nearbyBle,
    LoomDestinationNodeDiscovery? destinationNodeDiscovery,
    LoomDirectHttpPoster? destinationNodePoster,
  }) {
    final root = Directory(applicationSupportPath);
    root.createSync(recursive: true);

    LoomCryptoStateStore? crypto;
    LoomV2MessageStateStore? messageState;
    LoomAccountRootStoreV2? accountRoots;
    LoomDeviceDirectoryStoreV2? directory;
    LoomSqlitePacketStore? packetStore;
    LoomSqlitePacketRouteStore? packetRouteStore;
    LoomSqliteReplicaIntakeStore? replicaIntake;
    final directPoster = destinationNodePoster ?? LoomIoDirectHttpPoster();
    final ownsDirectPoster = destinationNodePoster == null;
    try {
      crypto = LoomCryptoStateStore.openFile(
        '${root.path}/loom-crypto-v2.sqlite3',
      );
      messageState = LoomV2MessageStateStore.openFile(
        '${root.path}/loom-message-state-v2.sqlite3',
      );
      accountRoots = LoomAccountRootStoreV2.openFile(
        '${root.path}/loom-account-roots-v2.sqlite3',
      );
      directory = LoomDeviceDirectoryStoreV2.openFile(
        '${root.path}/loom-device-directory-v2.sqlite3',
      );
      final dtnPath = '${root.path}/loom-dtn-v2.sqlite3';
      packetStore = LoomSqlitePacketStore.openFile(dtnPath);
      packetRouteStore = LoomSqlitePacketRouteStore.openExistingFile(dtnPath);
      replicaIntake = LoomSqliteReplicaIntakeStore.openExistingFile(dtnPath);

      final configuredProtector =
          stateProtector ??
          (Platform.isAndroid ? LoomAndroidKeystoreStateProtector() : null);
      final coordinator = reviewedSessionProvider == null
          ? null
          : LoomV2OutgoingMessageCoordinator(
              transactionRunner: crypto,
              sessionProvider: reviewedSessionProvider,
            );
      final radioStack =
          nearbyRadios ?? LoomAndroidNearbyRadioStack(ble: nearbyBle);
      final signatureVerifier = LoomStoredAccountSignatureVerifierV2(
        rootStore: accountRoots,
      );
      final transferExecutor = LoomDtnTransferExecutor(
        packetStore: packetStore,
        transferStore: packetStore,
      );
      final nearbyDtnEncounters = LoomNearbyDtnEncounterCoordinator(
        packetStore: packetStore,
        transferExecutor: transferExecutor,
        routeStore: packetRouteStore,
        durablyAccept:
            ({required transmissionId, required exactOuterEnvelopeBytes}) {
              final result = replicaIntake!.acceptReplica(
                exactOuterEnvelopeBytes: exactOuterEnvelopeBytes,
                now: DateTime.now().toUtc(),
              );
              return LoomDtnHopAck(
                transmissionId: transmissionId,
                packetId: result.packetId,
                acceptedAt: result.storedAt,
                duplicate:
                    result.disposition ==
                    LoomReplicaIntakeDisposition.duplicate,
              );
            },
        durablyAcceptRouted:
            ({
              required transmissionId,
              required exactOuterEnvelopeBytes,
              required destinationNodeDomain,
            }) {
              final result = replicaIntake!.acceptReplica(
                exactOuterEnvelopeBytes: exactOuterEnvelopeBytes,
                now: DateTime.now().toUtc(),
              );
              if (destinationNodeDomain != null) {
                packetRouteStore!.rememberDestinationRoute(
                  packetId: result.packetId,
                  destinationNodeDomain: destinationNodeDomain,
                  now: result.storedAt,
                );
              }
              return LoomDtnHopAck(
                transmissionId: transmissionId,
                packetId: result.packetId,
                acceptedAt: result.storedAt,
                duplicate:
                    result.disposition ==
                    LoomReplicaIntakeDisposition.duplicate,
              );
            },
      );
      return LoomV2MessagingRuntime._(
        cryptoStateStore: crypto,
        messageStateStore: messageState,
        accountRootStore: accountRoots,
        accountSignatureVerifier: signatureVerifier,
        deviceDirectoryStore: directory,
        packetStore: packetStore,
        packetRouteStore: packetRouteStore,
        replicaIntakeStore: replicaIntake,
        transferExecutor: transferExecutor,
        packetCustodyService: LoomV2PacketCustodyService(
          packetStore: packetStore,
        ),
        nearbyDtnEncounters: nearbyDtnEncounters,
        nearbyRadios: radioStack,
        stateProtector: configuredProtector,
        sessionProvider: reviewedSessionProvider,
        outgoingCoordinator: coordinator,
        destinationNodeDiscovery:
            destinationNodeDiscovery ?? LoomNodeClient().discoverDomain,
        destinationNodePoster: directPoster,
        ownsDestinationNodePoster: ownsDirectPoster,
      );
    } catch (_) {
      packetRouteStore?.close();
      replicaIntake?.close();
      packetStore?.close();
      directory?.close();
      accountRoots?.close();
      messageState?.close();
      crypto?.close();
      if (ownsDirectPoster && directPoster is LoomIoDirectHttpPoster) {
        directPoster.close(force: true);
      }
      rethrow;
    }
  }

  LoomAndroidBleRadioAdapter get nearbyBle => nearbyRadios.ble;

  LoomV2SendReadiness get sendReadiness {
    if (sessionProvider == null) {
      return LoomV2SendReadiness.blockedProviderReview;
    }
    if (stateProtector == null) {
      return LoomV2SendReadiness.blockedStateProtection;
    }
    return LoomV2SendReadiness.providerAndStateProtectionSupplied;
  }

  bool get productionSendEnabled =>
      !_closed &&
      sendReadiness == LoomV2SendReadiness.providerAndStateProtectionSupplied;

  Future<bool> stateProtectionAvailable() async {
    _requireOpen();
    final protector = stateProtector;
    if (protector == null) return false;
    if (protector is LoomAndroidKeystoreStateProtector) {
      return protector.isAvailable();
    }
    return true;
  }

  Future<Set<LoomNearbyBearer>> supportedNearbyBearers() async {
    _requireOpen();
    if (!Platform.isAndroid) return const <LoomNearbyBearer>{};
    return nearbyRadios.supportedBearers();
  }

  Future<bool> nearbyBleSupported() async {
    _requireOpen();
    return nearbyBle.isSupported();
  }

  Future<LoomConnectivityCapabilities> connectivitySnapshot({
    required DateTime now,
    bool internetReachable = false,
    bool homeNodeReachable = false,
    bool destinationNodeReachable = false,
    bool domesticRelayReachable = false,
    bool globalRelayReachable = false,
    bool lanAvailable = false,
    int authenticatedNearbyPeerCount = 0,
    int verifiedGatewayCount = 0,
    bool backgroundRestricted = false,
    bool storagePressure = false,
    bool batterySaver = false,
  }) async {
    _requireOpen();
    final bearers = await supportedNearbyBearers();
    final executionPolicy = backgroundRestricted
        ? LoomExecutionPolicy.backgroundRestricted
        : _foregroundBearer == null
        ? LoomExecutionPolicy.foregroundInteractive
        : LoomExecutionPolicy.foregroundService;
    return LoomConnectivityCapabilities(
      observedAt: now.toUtc(),
      internetReachable: internetReachable,
      homeNodeReachable: homeNodeReachable,
      destinationNodeReachable: destinationNodeReachable,
      domesticRelayReachable: domesticRelayReachable,
      globalRelayReachable: globalRelayReachable,
      lanAvailable: lanAvailable,
      nearbyBearers: bearers,
      authenticatedNearbyPeerCount: authenticatedNearbyPeerCount,
      verifiedGatewayCount: verifiedGatewayCount,
      executionPolicy: executionPolicy,
      storagePressure: storagePressure,
      batterySaver: batterySaver,
    );
  }

  Future<bool> enableNearbyForegroundMode({
    LoomNearbyBearer? preferredBearer,
  }) async {
    _requireOpen();
    final supported = await supportedNearbyBearers();
    if (supported.isEmpty) return false;
    final bearer =
        preferredBearer != null && supported.contains(preferredBearer)
        ? preferredBearer
        : supported.contains(LoomNearbyBearer.wifiAware)
        ? LoomNearbyBearer.wifiAware
        : supported.contains(LoomNearbyBearer.wifiDirect)
        ? LoomNearbyBearer.wifiDirect
        : LoomNearbyBearer.bluetoothLowEnergy;
    if (!await nearbyRadios.requestPermissionsFor(<LoomNearbyBearer>{bearer})) {
      return false;
    }
    await nearbyRadios.startForegroundMode(bearer);
    _foregroundBearer = bearer;
    return true;
  }

  Future<void> disableNearbyForegroundMode() async {
    if (_closed || _foregroundBearer == null) return;
    _foregroundBearer = null;
    await nearbyRadios.stopForegroundMode();
  }

  LoomNearbyRadioAdapter nearbyRadioFor(LoomNearbyBearer bearer) {
    _requireOpen();
    return nearbyRadios.adapterFor(bearer);
  }

  Future<LoomNearbyDtnEncounterResult> forwardNearbyDtnOverLink({
    required LoomNearbyLink link,
    required LoomDirectTransportSigner signer,
    bool localCanStoreCarry = false,
    int maxPackets = 8,
  }) {
    _requireOpen();
    return nearbyDtnEncounters.forwardOverLink(
      link: link,
      signer: signer,
      localCanStoreCarry: localCanStoreCarry,
      maxPackets: maxPackets,
    );
  }

  Future<int> acceptNearbyDtnOverLink({
    required LoomNearbyLink link,
    required LoomDirectTransportSigner signer,
    required bool localCanStoreCarry,
    int maxPackets = 8,
    Duration idleTimeout = const Duration(seconds: 20),
  }) {
    _requireOpen();
    return nearbyDtnEncounters.acceptOverLink(
      link: link,
      signer: signer,
      localCanStoreCarry: localCanStoreCarry,
      maxPackets: maxPackets,
      idleTimeout: idleTimeout,
    );
  }

  /// Commits a gateway-routed Nearby replica and its bounded destination hint
  /// before returning custody. The Destination Node upload is only kicked after
  /// both durable writes complete, and is deliberately not awaited by the
  /// Nearby hop ACK path.
  Future<LoomDtnHopAck> acceptNearbyInternetGatewayReplica({
    required String transmissionId,
    required Uint8List exactOuterEnvelopeBytes,
    required String destinationNodeDomain,
    required LoomDirectTransportSigner signer,
  }) async {
    _requireOpen();
    final result = replicaIntakeStore.acceptReplica(
      exactOuterEnvelopeBytes: exactOuterEnvelopeBytes,
      now: DateTime.now().toUtc(),
    );
    packetRouteStore.rememberDestinationRoute(
      packetId: result.packetId,
      destinationNodeDomain: destinationNodeDomain,
      now: result.storedAt,
    );
    final ack = LoomDtnHopAck(
      transmissionId: transmissionId,
      packetId: result.packetId,
      acceptedAt: result.storedAt,
      duplicate: result.disposition == LoomReplicaIntakeDisposition.duplicate,
    );
    kickDestinationNodeUplink(signer);
    return ack;
  }

  Future<int> acceptNearbyInternetGatewayOverLink({
    required LoomNearbyLink link,
    required LoomDirectTransportSigner signer,
    required bool internetGatewayAvailable,
    int maxPackets = 8,
    Duration idleTimeout = const Duration(seconds: 20),
  }) {
    _requireOpen();
    return _internetGatewayEncounter(signer).acceptOverLink(
      link: link,
      signer: signer,
      internetGatewayAvailable: internetGatewayAvailable,
      maxPackets: maxPackets,
      idleTimeout: idleTimeout,
    );
  }

  Future<LoomNearbyInternetGatewayForwardResult>
  forwardNearbyInternetGatewayOverLink({
    required LoomNearbyLink link,
    required LoomDirectTransportSigner signer,
    int maxPackets = 8,
  }) {
    _requireOpen();
    return _internetGatewayEncounter(
      signer,
    ).forwardOverLink(link: link, signer: signer, maxPackets: maxPackets);
  }

  /// Schedules a single-flight Destination Node drain. Repeated kicks while a
  /// drain is active are coalesced into one follow-up pass, which makes resume,
  /// foreground and custody events safe to call aggressively.
  void kickDestinationNodeUplink(LoomDirectTransportSigner signer) {
    _requireOpen();
    _destinationUplinkSigner = signer;
    _destinationUplinkKickPending = true;
    _ensureDestinationUplinkDrain();
  }

  Future<void> waitForDestinationNodeUplinkIdle() async {
    while (true) {
      final drain = _destinationUplinkDrain;
      if (drain == null) return;
      await drain;
    }
  }

  LoomNearbyInternetGatewayEncounter _internetGatewayEncounter(
    LoomDirectTransportSigner signer,
  ) => LoomNearbyInternetGatewayEncounter(
    packetStore: packetStore,
    routeStore: packetRouteStore,
    transferExecutor: transferExecutor,
    durablyAccept:
        ({
          required transmissionId,
          required exactOuterEnvelopeBytes,
          required destinationNodeDomain,
        }) => acceptNearbyInternetGatewayReplica(
          transmissionId: transmissionId,
          exactOuterEnvelopeBytes: exactOuterEnvelopeBytes,
          destinationNodeDomain: destinationNodeDomain,
          signer: signer,
        ),
  );

  void _ensureDestinationUplinkDrain() {
    if (_closed ||
        _destinationUplinkDrain != null ||
        !_destinationUplinkKickPending ||
        _destinationUplinkSigner == null) {
      return;
    }
    late final Future<void> drain;
    drain = _drainDestinationNodeUplinkLoop();
    _destinationUplinkDrain = drain;
    unawaited(
      drain.whenComplete(() {
        if (!identical(_destinationUplinkDrain, drain)) return;
        _destinationUplinkDrain = null;
        _ensureDestinationUplinkDrain();
      }),
    );
  }

  Future<void> _drainDestinationNodeUplinkLoop() async {
    while (!_closed && _destinationUplinkKickPending) {
      _destinationUplinkKickPending = false;
      final signer = _destinationUplinkSigner;
      if (signer == null) return;
      try {
        await LoomDestinationNodeUplink(
          packetStore: packetStore,
          routeStore: packetRouteStore,
          transferExecutor: transferExecutor,
          signer: signer,
          discoverNode: _destinationNodeDiscovery,
          poster: _destinationNodePoster,
        ).drain();
      } catch (_) {
        // Network/discovery failure is already represented by durable retry
        // state where possible. A foreground/resume/custody kick retries later.
      }
    }
  }

  /// Legacy compatibility accessor. New code should select via capability
  /// snapshot and [nearbyRadioFor].
  LoomNearbyRadioAdapter get nearbyRadio {
    _requireOpen();
    return nearbyBle;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _destinationUplinkKickPending = false;
    _destinationUplinkSigner = null;
    _foregroundBearer = null;
    packetRouteStore.close();
    replicaIntakeStore.close();
    packetStore.close();
    deviceDirectoryStore.close();
    accountRootStore.close();
    messageStateStore.close();
    cryptoStateStore.close();
    if (_ownsDestinationNodePoster &&
        _destinationNodePoster is LoomIoDirectHttpPoster) {
      _destinationNodePoster.close();
    }
  }

  void _requireOpen() {
    if (_closed) throw StateError('LoomV2MessagingRuntime is closed');
  }
}
