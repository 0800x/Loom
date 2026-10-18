import 'dart:async';

import 'package:loom_crypto_bridge/loom_crypto_bridge.dart';
import 'package:loom_models/loom_models.dart';
import 'package:loom_next/features/nodes/application/node_directory_controller.dart';
import 'package:loom_next/features/onboarding/application/onboarding_controller.dart';
import 'package:loom_protocol/loom_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

LoomIdentityPublic _identity(String id, {int year = 2020}) =>
    LoomIdentityPublic(
      identityId: 'chn:$id',
      publicKey: 'public-$id',
      fingerprint: 'fingerprint-$id',
      createdAt: DateTime.utc(year),
    );

final _words = List<String>.filled(24, 'private-word');
LoomPendingIdentity _pending(LoomIdentityPublic identity) =>
    LoomPendingIdentity(
      identity: identity,
      recovery: LoomRecoveryMaterial(
        mnemonicWords: _words,
        recoveryId: 'recovery',
      ),
    );

const _receipt = LoomRegistrationReceipt(
  accountId: 'account',
  deviceId: 'device',
  address: '@alice:home.example',
  homeNode: 'home.example',
);

class _Core implements LoomIdentityCore {
  _Core({this.stored, required this.recovered});
  LoomIdentityPublic? stored;
  final LoomIdentityPublic recovered;
  Object? restoreError;
  Object? readError;
  int commits = 0;
  int discards = 0;
  LoomPendingIdentity? committed;
  Completer<void>? readGate;
  Completer<void>? readStarted;
  Completer<void>? commitGate;
  Completer<void>? commitStarted;
  Completer<void>? restoreGate;
  Completer<void>? restoreStarted;

  @override
  Future<LoomIdentityPublic?> readIdentity() async {
    readStarted?.complete();
    await readGate?.future;
    if (readError != null) throw readError!;
    return stored;
  }

  @override
  Future<LoomPendingIdentity> restoreIdentityFromWords(
    List<String> words,
  ) async {
    restoreStarted?.complete();
    await restoreGate?.future;
    if (restoreError != null) throw restoreError!;
    return _pending(recovered);
  }

  @override
  Future<void> commitPendingIdentity(LoomPendingIdentity pending) async {
    commits++;
    committed = pending;
    stored = pending.identity;
    commitStarted?.complete();
    await commitGate?.future;
  }

  @override
  void discardPendingIdentity() => discards++;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Nodes extends LoomNodeDirectoryController {
  int discoveries = 0;
  _Nodes() {
    selectedEndpoint = Uri.parse('https://home.example');
    selectedNode = const LoomNodeDescriptor(
      nodeId: 'node',
      name: 'Home',
      domain: 'home.example',
      operatorCountry: '—',
      networkLocation: 'test',
      registration: 'open',
      federation: false,
      protocols: [],
      publicKey: 'key',
      fingerprint: 'fp',
      capabilities: [],
    );
    selectedLiveInfo = const LoomNodeLiveInfo(
      nodeId: 'node',
      serverVersion: 'test',
      protocolVersion: 'loom-node-v1',
      registration: 'open',
      federationMode: 'disabled',
      capabilities: [],
    );
  }
  @override
  bool get selectedNodeVerified => true;
  @override
  Future<void> discoverAndSelectDomain(
    String domain, {
    String? expectedFingerprint,
    String? expectedNodeId,
  }) async {
    discoveries++;
  }
}

class _NodeClient extends LoomNodeClient {
  int logins = 0;
  int registrations = 0;
  Completer<void>? registrationGate;
  Completer<void>? registrationStarted;
  Object? loginError;
  String identityId = 'chn:same';
  @override
  Future<LoomRegistrationResult> registerIdentity({
    required Uri baseUri,
    required String username,
    required String displayName,
    required String password,
    required LoomIdentityPublic identity,
    required String deviceName,
  }) async {
    registrations++;
    registrationStarted?.complete();
    await registrationGate?.future;
    return const LoomRegistrationResult(
      receipt: _receipt,
      accessToken: 'access',
      refreshToken: 'refresh',
      accessTokenExpiresInSeconds: 900,
    );
  }

  @override
  Future<LoomLoginResult> login({
    required Uri baseUri,
    required String username,
    required String password,
  }) async {
    logins++;
    if (loginError != null) throw loginError!;
    return LoomLoginResult(
      receipt: _receipt,
      identityId: identityId,
      accessToken: 'access',
      refreshToken: 'refresh',
      accessTokenExpiresInSeconds: 900,
    );
  }
}

class _Verifier extends LoomPinnedNodeVerifier {
  Completer<void>? gate;
  Completer<void>? started;
  @override
  Future<void> verify({
    required Uri baseUri,
    required String expectedNodeId,
    required String expectedPublicKey,
  }) async {
    started?.complete();
    await gate?.future;
  }
}

class _Vault implements LoomSessionVault {
  int writes = 0;
  Completer<void>? gate;
  Completer<void>? started;
  @override
  Future<void> write(LoomStoredSession stored) async {
    writes++;
    started?.complete();
    await gate?.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Credentials implements LoomCredentialVault {
  int writes = 0;
  @override
  Future<void> writeRefreshToken({
    required String homeNode,
    required String deviceId,
    required String refreshToken,
  }) async => writes++;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Security extends LoomSecurityClient {
  int publications = 0;
  @override
  Future<void> publishDeviceBundle({
    required Uri baseUri,
    required String accessToken,
    required LoomDeviceKeyBundle bundle,
    LoomDeviceRequestProofProvider? deviceProofProvider,
  }) async => publications++;
}

class _DeviceCore implements LoomDeviceSecurityCore {
  LoomDeviceKeyBundle? bundle;
  int creations = 0;
  @override
  Future<LoomDeviceKeyBundle> createOrLoadDevice({
    required LoomIdentityPublic identity,
    required String deviceId,
    required String deviceName,
    required LoomIdentitySigner identitySigner,
  }) async {
    creations++;
    return bundle = LoomDeviceKeyBundle(
      bundleVersion: 1,
      identityId: identity.identityId,
      deviceId: deviceId,
      deviceName: deviceName,
      signingPublicKey: 'signing',
      agreementPublicKey: 'agreement',
      createdAt: DateTime.utc(2020),
      capabilities: [],
      fingerprint: 'device-fp',
      deviceSignature: 'signature',
      identitySignature: 'identity-signature',
    );
  }

  @override
  Future<LoomDeviceKeyBundle?> readDevice({
    required String identityId,
    required String deviceId,
  }) async => bundle;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _Core core;
  late _Nodes nodes;
  late _NodeClient client;
  late _Vault sessions;
  late _Credentials credentials;
  late _Verifier verifier;
  late _DeviceCore deviceCore;
  late _Security security;
  late LoomOnboardingController controller;
  void setup({LoomIdentityPublic? stored, LoomIdentityPublic? recovered}) {
    core = _Core(stored: stored, recovered: recovered ?? _identity('same'));
    nodes = _Nodes();
    client = _NodeClient();
    sessions = _Vault();
    credentials = _Credentials();
    verifier = _Verifier();
    deviceCore = _DeviceCore();
    security = _Security();
    controller = LoomOnboardingController(
      nodes: nodes,
      identityCore: core,
      nodeClient: client,
      sessionVault: sessions,
      credentialVault: credentials,
      nodeVerifier: verifier,
      deviceSecurityCore: deviceCore,
      securityClient: security,
    );
    addTearDown(controller.dispose);
    addTearDown(nodes.dispose);
  }

  Future<bool> signIn() => controller.signIn(
    nodeDomain: 'home.example',
    username: 'alice',
    password: 'password',
  );

  test(
    'different recovery preserves active identity, receipt and access',
    () async {
      final original = _identity('original');
      setup(stored: original, recovered: _identity('different'));
      controller.committedIdentity = original;
      controller.receipt = _receipt;
      controller.accessToken = 'original-token';
      controller.status = LoomOnboardingStatus.complete;
      expect(await controller.restoreIdentityWords(_words.join(' ')), isFalse);
      expect(core.stored, same(original));
      expect(controller.committedIdentity, same(original));
      expect(controller.receipt, same(_receipt));
      expect(controller.accessToken, 'original-token');
      expect(controller.pendingIdentity, isNull);
      expect(core.commits, 0);
      expect(nodes.discoveries, 0);
      expect(sessions.writes + credentials.writes, 0);
      expect(controller.errorMessage, isNot(contains('private-word')));
    },
  );

  test(
    'identity retained after sign-out also blocks another recovery',
    () async {
      final original = _identity('original');
      setup(stored: original, recovered: _identity('different'));
      expect(controller.committedIdentity, isNull);
      expect(await controller.restoreIdentityWords(_words.join(' ')), isFalse);
      expect(core.stored, same(original));
      expect(core.commits, 0);
    },
  );

  test('same-identity recovery and sign-in retain original metadata', () async {
    final original = _identity('same', year: 2019);
    setup(stored: original, recovered: _identity('same', year: 2026));
    controller.committedIdentity = original;
    expect(await controller.restoreIdentityWords(_words.join(' ')), isTrue);
    expect(controller.pendingIdentity!.identity, same(original));
    expect(await signIn(), isTrue);
    expect(core.commits, 1);
    expect(core.committed!.identity, same(original));
    expect(controller.committedIdentity, same(original));
    expect(controller.receipt, same(_receipt));
    expect(sessions.writes, 1);
    expect(credentials.writes, 1);
  });

  test(
    'invalid mnemonic error does not disclose input or alter stored identity',
    () async {
      final original = _identity('same');
      setup(stored: original);
      core.restoreError = const FormatException('invalid word private-word');
      expect(await controller.restoreIdentityWords(_words.join(' ')), isFalse);
      expect(controller.errorMessage, isNot(contains('private-word')));
      expect(core.stored, same(original));
      expect(core.commits, 0);
      expect(controller.pendingIdentity, isNull);
    },
  );

  test('unreadable identity vault prevents staging or overwriting', () async {
    setup();
    core.readError = StateError('vault is locked');
    expect(await controller.restoreIdentityWords(_words.join(' ')), isFalse);
    expect(controller.pendingIdentity, isNull);
    expect(core.commits, 0);
    expect(nodes.discoveries, 0);
  });

  test(
    'different pending identity fails before discovery, login or commit',
    () async {
      final original = _identity('original');
      setup(stored: original);
      controller.committedIdentity = original;
      controller.pendingIdentity = _pending(_identity('different'));
      controller.receipt = _receipt;
      expect(await signIn(), isFalse);
      expect(nodes.discoveries, 0);
      expect(client.logins, 0);
      expect(core.commits, 0);
      expect(core.stored, same(original));
      expect(controller.receipt, same(_receipt));
      expect(sessions.writes + credentials.writes, 0);
    },
  );

  test('incorrect server password does not commit restored identity', () async {
    setup();
    expect(await controller.restoreIdentityWords(_words.join(' ')), isTrue);
    client.loginError = const LoomProtocolException('invalid_credentials');
    expect(await signIn(), isFalse);
    expect(core.commits, 0);
    expect(core.stored, isNull);
    expect(sessions.writes + credentials.writes, 0);
    expect(controller.errorMessage, 'The username or password is incorrect.');
  });

  test(
    'registration cannot replace a stored identity with a different pending identity',
    () async {
      final original = _identity('original');
      setup(stored: original);
      controller.committedIdentity = original;
      controller.pendingIdentity = _pending(_identity('different'));
      controller.receipt = _receipt;
      expect(await controller.commitAndRegister(), isFalse);
      expect(client.registrations, 0);
      expect(core.commits, 0);
      expect(core.stored, same(original));
      expect(controller.receipt, same(_receipt));
      expect(sessions.writes + credentials.writes, 0);
    },
  );

  test(
    'server account mismatch cannot commit a fresh restored identity',
    () async {
      setup();
      expect(await controller.restoreIdentityWords(_words.join(' ')), isTrue);
      client.identityId = 'chn:other';
      expect(await signIn(), isFalse);
      expect(core.commits, 0);
      expect(core.stored, isNull);
      expect(sessions.writes + credentials.writes, 0);
    },
  );

  test(
    'duplicate registration during validation starts only one attempt',
    () async {
      setup();
      controller.pendingIdentity = _pending(_identity('same'));
      core.readGate = Completer<void>();
      core.readStarted = Completer<void>();
      final first = controller.commitAndRegister();
      await core.readStarted!.future;
      expect(await controller.commitAndRegister(), isFalse);
      core.readGate!.complete();
      expect(await first, isTrue);
      expect(client.registrations, 1);
      expect(core.commits, 1);
      expect(sessions.writes, 1);
    },
  );

  test(
    'registration cancelled during validation performs no later writes',
    () async {
      setup();
      controller.pendingIdentity = _pending(_identity('same'));
      core.readGate = Completer<void>();
      core.readStarted = Completer<void>();
      final attempt = controller.commitAndRegister();
      await core.readStarted!.future;
      controller.resetPending();
      core.readGate!.complete();
      expect(await attempt, isFalse);
      expect(client.registrations, 0);
      expect(core.commits, 0);
      expect(deviceCore.creations, 0);
      expect(sessions.writes + credentials.writes, 0);
      expect(controller.status, LoomOnboardingStatus.idle);
    },
  );

  test(
    'late registration response after logout cannot activate an identity',
    () async {
      setup();
      controller.pendingIdentity = _pending(_identity('same'));
      client.registrationGate = Completer<void>();
      client.registrationStarted = Completer<void>();
      final attempt = controller.commitAndRegister();
      await client.registrationStarted!.future;
      controller.resetPending();
      client.registrationGate!.complete();
      expect(await attempt, isFalse);
      expect(core.commits, 0);
      expect(deviceCore.creations, 0);
      expect(sessions.writes + credentials.writes, 0);
      expect(controller.committedIdentity, isNull);
      expect(controller.receipt, isNull);
      expect(controller.accessToken, isNull);
      expect(controller.status, LoomOnboardingStatus.idle);
    },
  );

  test(
    'lock invalidation during node challenge prevents sending credentials',
    () async {
      setup(stored: _identity('same'));
      verifier.gate = Completer<void>();
      verifier.started = Completer<void>();
      final attempt = signIn();
      await verifier.started!.future;
      controller.clearTransientSecrets();
      verifier.gate!.complete();
      expect(await attempt, isFalse);
      expect(client.logins, 0);
      expect(core.commits, 0);
      expect(deviceCore.creations, 0);
      expect(sessions.writes + credentials.writes, 0);
      expect(controller.accessToken, isNull);
    },
  );

  test(
    'logout during identity commit prevents subsequent device and session writes',
    () async {
      setup();
      expect(await controller.restoreIdentityWords(_words.join(' ')), isTrue);
      core.commitGate = Completer<void>();
      core.commitStarted = Completer<void>();
      final attempt = signIn();
      await core.commitStarted!.future;
      controller.resetPending();
      core.commitGate!.complete();
      expect(await attempt, isFalse);
      expect(
        core.commits,
        1,
        reason: 'the already-started storage commit cannot be rolled back',
      );
      expect(deviceCore.creations, 0);
      expect(security.publications, 0);
      expect(sessions.writes + credentials.writes, 0);
      expect(controller.committedIdentity, isNull);
      expect(controller.receipt, isNull);
      expect(controller.accessToken, isNull);
      expect(controller.status, LoomOnboardingStatus.idle);
    },
  );

  test(
    'late session persistence completion cannot undo logout state',
    () async {
      setup(stored: _identity('same'));
      sessions.gate = Completer<void>();
      sessions.started = Completer<void>();
      final attempt = signIn();
      await sessions.started!.future;
      controller.resetPending();
      sessions.gate!.complete();
      expect(await attempt, isFalse);
      expect(controller.committedIdentity, isNull);
      expect(controller.receipt, isNull);
      expect(controller.accessToken, isNull);
      expect(controller.status, LoomOnboardingStatus.idle);
    },
  );

  test(
    'invalidated recovery finishes before another preparation can start',
    () async {
      setup();
      core.restoreGate = Completer<void>();
      core.restoreStarted = Completer<void>();
      final oldRestore = controller.restoreIdentityWords(_words.join(' '));
      await core.restoreStarted!.future;
      controller.resetPending();
      expect(await controller.restoreIdentityWords(_words.join(' ')), isFalse);
      expect(
        await controller.createIdentity(
          username: 'alice',
          displayName: 'Alice',
          password: 'long-enough-password',
        ),
        isFalse,
      );
      expect(await signIn(), isFalse);
      expect(await controller.commitAndRegister(), isFalse);
      core.restoreGate!.complete();
      expect(await oldRestore, isFalse);
      expect(controller.pendingIdentity, isNull);
      expect(controller.status, LoomOnboardingStatus.idle);
      expect(core.commits, 0);
      expect(client.logins + client.registrations, 0);
      core.restoreGate = null;
      core.restoreStarted = null;
      expect(await controller.restoreIdentityWords(_words.join(' ')), isTrue);
      expect(controller.pendingIdentity, isNotNull);
    },
  );
}
