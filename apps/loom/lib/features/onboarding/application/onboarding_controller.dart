import 'dart:async';
import 'dart:io';

import '../../profile/application/local_avatar_store.dart';

import 'package:loom_crypto_bridge/loom_crypto_bridge.dart';
import 'package:loom_models/loom_models.dart';
import 'package:loom_protocol/loom_protocol.dart';
import 'package:flutter/widgets.dart';

import '../../nodes/application/node_directory_controller.dart';

enum LoomOnboardingStatus {
  idle,
  creatingIdentity,
  recoveryReady,
  registering,
  complete,
  error,
}

class LoomOnboardingController extends ChangeNotifier {
  LoomOnboardingController({
    required this.nodes,
    LoomIdentityCore? identityCore,
    LoomDeviceSecurityCore? deviceSecurityCore,
    LoomCredentialVault? credentialVault,
    LoomSessionVault? sessionVault,
    LoomNodeClient? nodeClient,
    LoomPinnedNodeVerifier? nodeVerifier,
    LoomSecurityClient? securityClient,
    LoomDeviceBoundSessionClient? deviceBoundSessionClient,
  }) : _identityCore = identityCore ?? LoomIdentityCoreV1(),
       _deviceSecurityCore = deviceSecurityCore ?? LoomDeviceSecurityCoreV1(),
       _credentialVault = credentialVault ?? LoomSecureCredentialVault(),
       _sessionVault = sessionVault ?? LoomSecureSessionVault(),
       _nodeClient = nodeClient ?? LoomNodeClient(),
       _nodeVerifier = nodeVerifier ?? LoomPinnedNodeVerifier(),
       _securityClient = securityClient ?? LoomSecurityClient(),
       _deviceBoundSessionClient =
           deviceBoundSessionClient ?? LoomDeviceBoundSessionClient();

  final LoomNodeDirectoryController nodes;
  final LoomIdentityCore _identityCore;
  final LoomDeviceSecurityCore _deviceSecurityCore;
  final LoomCredentialVault _credentialVault;
  final LoomSessionVault _sessionVault;
  final LoomNodeClient _nodeClient;
  final LoomPinnedNodeVerifier _nodeVerifier;
  final LoomSecurityClient _securityClient;
  final LoomDeviceBoundSessionClient _deviceBoundSessionClient;
  bool _restoreAttempted = false;
  Future<bool>? _restoreFuture;
  LoomStoredSession? _storedSession;

  LoomOnboardingStatus status = LoomOnboardingStatus.idle;
  LoomPendingIdentity? pendingIdentity;
  LoomIdentityPublic? committedIdentity;
  LoomRegistrationReceipt? receipt;
  String? accessToken;
  DateTime? accessTokenExpiresAt;
  String? errorMessage;
  String username = '';
  String displayName = '';
  String password = '';
  Future<bool>? _refreshFuture;
  int _sessionEpoch = 0;
  bool _disposed = false;
  // IdentityCore owns one pending secret buffer. Logout invalidates an
  // attempt, but cannot cancel its derivation; keep preparations serialized
  // until that old future has finished and discarded its material.
  bool _preparingIdentity = false;
  bool _isCurrent(int epoch) =>
      !_disposed && epoch == _sessionEpoch && !LoomAppLock.instance.locked;

  // The canonical address survives process death and is the source of truth;
  // the registration form is not an account database.
  void _restoreAccountName() {
    final address = receipt?.address;
    if (address == null) {
      return;
    }
    username = LoomAddress.parseCanonical(address).username;
  }

  void clearTransientSecrets() {
    _sessionEpoch++;
    // A new unlock must not join an attempt that started before the lock.
    _restoreFuture = null;
    _restoreAttempted = false;
    _refreshFuture = null;
    password = '';
    accessToken = null;
    accessTokenExpiresAt = null;
    _identityCore.discardPendingIdentity();
    final hadPending = pendingIdentity != null;
    pendingIdentity = null;
    // Locked mid-setup: screens observe this notifier through
    // InheritedNotifier and must repaint the cleared state after unlock.
    if (hadPending) {
      notifyListeners();
    }
  }

  Future<bool> restorePersistedSession() {
    final pending = _restoreFuture;
    if (pending != null) {
      return pending;
    }
    late final Future<bool> attempt;
    attempt = _restorePersistedSession().whenComplete(() {
      if (identical(_restoreFuture, attempt)) {
        _restoreFuture = null;
      }
    });
    return _restoreFuture = attempt;
  }

  void _requireCurrentRestore(int epoch) {
    if (!_isCurrent(epoch)) {
      throw StateError('Session restore is suspended until Loom is unlocked');
    }
  }

  Future<bool> _restorePersistedSession() async {
    final epoch = _sessionEpoch;
    // The initial value of `locked` is false until the native status is read.
    // Do not mistake protected storage at cold start for a new installation.
    await LoomAppLock.instance.initialize();
    _requireCurrentRestore(epoch);
    if (_restoreAttempted) {
      return status == LoomOnboardingStatus.complete;
    }
    try {
      final identity = await _identityCore.readIdentity();
      final stored = await _sessionVault.read();
      _requireCurrentRestore(epoch);
      if (stored == null) {
        if (identity == null && LoomAppLock.instance.enabled) {
          throw const FormatException(
            'Protected account storage is unavailable',
          );
        }
        // A successful empty read (fresh install or explicit sign-out) is the
        // only path to onboarding. Read/decryption failures must remain errors.
        committedIdentity = identity;
        _restoreAttempted = true;
        return false;
      }
      if (identity == null) {
        throw const FormatException('Saved session identity is unavailable');
      }
      nodes.restoreTrustedSelection(
        node: stored.node,
        endpoint: stored.endpoint,
        liveInfo: stored.liveInfo,
      );
      _storedSession = stored;
      committedIdentity = identity;
      receipt = stored.receipt;
      _restoreAccountName();
      final profile = LoomLocalAvatarStore.forIdentity(identity.identityId);
      await profile.load();
      _requireCurrentRestore(epoch);
      displayName = profile.displayName ?? '';
      status = LoomOnboardingStatus.complete;
      _restoreAttempted = true;
      // Opening the saved account must not wait for Home Node connectivity.
      // Refresh in the background; callers share the same attempt.
      unawaited(refreshAccessToken());
      notifyListeners();
      return true;
    } catch (_) {
      if (_isCurrent(epoch)) {
        _restoreAttempted = false;
        errorMessage =
            'Could not open the saved Loom session. Retry after unlocking.';
        status = LoomOnboardingStatus.error;
        notifyListeners();
      }
      // Returning false here sent the user to Create account and cached that
      // result. Preserve every stored value and let StartupGate offer Retry.
      rethrow;
    }
  }

  Future<bool> refreshAccessToken() {
    final pending = _refreshFuture;
    if (pending != null) {
      return pending;
    }
    late final Future<bool> attempt;
    attempt = _refreshAccessToken().whenComplete(() {
      if (identical(_refreshFuture, attempt)) {
        _refreshFuture = null;
      }
    });
    return _refreshFuture = attempt;
  }

  Future<void> synchronizeProfile({bool force = false}) async {
    final identity = committedIdentity;
    final endpoint = nodes.selectedEndpoint;
    if (identity == null ||
        endpoint == null ||
        receipt == null ||
        LoomAppLock.instance.locked ||
        _disposed) {
      return;
    }
    final epoch = _sessionEpoch;
    final profile = LoomLocalAvatarStore.forIdentity(identity.identityId);
    await profile.load();
    if (!_isCurrent(epoch)) {
      return;
    }
    if (profile.displayName != null && displayName != profile.displayName) {
      displayName = profile.displayName!;
      notifyListeners();
    }
    if (!force && !profile.needsSync) {
      return;
    }
    try {
      final http = HttpClient();
      try {
        final client = LoomMessagingClient(
          baseUri: endpoint,
          accessTokenProvider: () async {
            if (accessToken == null ||
                accessTokenExpiresAt?.isBefore(
                      DateTime.now().add(const Duration(seconds: 30)),
                    ) ==
                    true) {
              if (!await refreshAccessToken()) {
                throw const LoomProtocolException('Access token unavailable');
              }
            }
            return accessToken!;
          },
          deviceProofProvider: await deviceRequestProofProvider(),
          refreshRejectedToken: refreshRejectedToken,
          httpClient: http,
        );
        await profile.synchronize(
          fetch: client.fetchOwnProfile,
          upload: client.updateOwnProfile,
          fallbackName: displayName.isNotEmpty ? displayName : username,
          force: force,
        );
        if (!_isCurrent(epoch) ||
            committedIdentity?.identityId != identity.identityId) {
          return;
        }
        displayName = profile.displayName ?? displayName;
        notifyListeners();
      } finally {
        http.close(force: true);
      }
    } catch (_) {
      /* Profile transport must not block encrypted messaging. */
    }
  }

  Future<bool> refreshRejectedToken(String rejectedToken) {
    if (accessToken != null && accessToken != rejectedToken) {
      return Future.value(true);
    }
    return refreshAccessToken();
  }

  Future<bool> _refreshAccessToken() async {
    final epoch = _sessionEpoch;
    if (!_isCurrent(epoch)) {
      return false;
    }
    try {
      final stored = _storedSession ?? await _sessionVault.read();
      if (stored == null) {
        return false;
      }
      final verifiedStored = await _reverifyStoredHomeNode(stored, epoch);
      if (!_isCurrent(epoch)) {
        return false;
      }
      _storedSession = verifiedStored;
      final identity = committedIdentity ?? await _identityCore.readIdentity();
      if (identity == null) {
        throw const LoomProtocolException('Local Loom identity is unavailable');
      }
      final proofProvider = await _deviceProofProviderFor(
        identity: identity,
        currentReceipt: verifiedStored.receipt,
      );
      final refreshToken = await _credentialVault.readRefreshToken(
        homeNode: verifiedStored.receipt.homeNode,
        deviceId: verifiedStored.receipt.deviceId,
      );
      if (refreshToken == null || refreshToken.isEmpty) {
        return false;
      }
      if (!_isCurrent(epoch)) {
        return false;
      }
      final refreshed = await _deviceBoundSessionClient.refreshSession(
        baseUri: verifiedStored.endpoint,
        refreshToken: refreshToken,
        deviceProofProvider: proofProvider,
      );
      if (!_isCurrent(epoch)) {
        return false;
      }
      if (refreshed.receipt.accountId != verifiedStored.receipt.accountId ||
          refreshed.receipt.deviceId != verifiedStored.receipt.deviceId ||
          refreshed.receipt.address.toLowerCase() !=
              verifiedStored.receipt.address.toLowerCase()) {
        throw const LoomProtocolException(
          'Refreshed session identity does not match this device',
        );
      }
      await _credentialVault.writeRefreshToken(
        homeNode: refreshed.receipt.homeNode,
        deviceId: refreshed.receipt.deviceId,
        refreshToken: refreshed.refreshToken,
      );
      if (!_isCurrent(epoch)) {
        return false;
      }
      receipt = refreshed.receipt;
      _restoreAccountName();
      accessToken = refreshed.accessToken;
      accessTokenExpiresAt = DateTime.now().toUtc().add(
        Duration(seconds: refreshed.accessTokenExpiresInSeconds),
      );
      errorMessage = null;
      notifyListeners();
      return true;
    } catch (error) {
      if (!_isCurrent(epoch)) {
        return false;
      }
      accessToken = null;
      accessTokenExpiresAt = null;
      final detail = error is LoomProtocolException
          ? error.message
          : error.toString().replaceAll(RegExp(r'[\r\n]+'), ' ');
      errorMessage =
          'Home Node or device security verification failed. Credentials were '
          'not accepted without the pinned Node and local device key. $detail';
      notifyListeners();
      return false;
    }
  }

  Future<LoomDeviceRequestProofProvider> deviceRequestProofProvider() async {
    if (_disposed || LoomAppLock.instance.locked) {
      throw StateError('Loom is locked');
    }
    final currentReceipt = receipt ?? _storedSession?.receipt;
    final identity = committedIdentity ?? await _identityCore.readIdentity();
    if (currentReceipt == null || identity == null) {
      throw const LoomProtocolException(
        'A signed-in Loom identity is required for device-bound requests',
      );
    }
    return _deviceProofProviderFor(
      identity: identity,
      currentReceipt: currentReceipt,
    );
  }

  Future<LoomDeviceRequestProofProvider> _deviceProofProviderFor({
    required LoomIdentityPublic identity,
    required LoomRegistrationReceipt currentReceipt,
  }) async {
    final bundle = await _deviceSecurityCore.readDevice(
      identityId: identity.identityId,
      deviceId: currentReceipt.deviceId,
    );
    if (bundle == null ||
        bundle.identityId != identity.identityId ||
        bundle.deviceId != currentReceipt.deviceId) {
      throw const LoomProtocolException(
        'This device has no valid local signing key. Sign in again to establish a new device.',
      );
    }
    return LoomDeviceRequestProofProvider(
      deviceId: currentReceipt.deviceId,
      signer: (payload) => _deviceSecurityCore.signDevicePayload(
        identityId: identity.identityId,
        deviceId: currentReceipt.deviceId,
        payload: payload,
      ),
    );
  }

  Future<LoomStoredSession> _reverifyStoredHomeNode(
    LoomStoredSession stored,
    int epoch,
  ) async {
    try {
      await nodes.discoverAndSelectDomain(stored.node.domain);
      if (!_isCurrent(epoch)) {
        throw StateError('Session changed');
      }
      final freshNode = nodes.selectedNode;
      final freshEndpoint = nodes.selectedEndpoint;
      final freshLiveInfo = nodes.selectedLiveInfo;
      if (!nodes.selectedNodeVerified ||
          freshNode == null ||
          freshEndpoint == null ||
          freshLiveInfo == null) {
        throw LoomProtocolException(
          nodes.errorMessage ?? 'Home Node could not be freshly verified',
        );
      }
      if (freshNode.nodeId != stored.node.nodeId ||
          freshNode.publicKey != stored.node.publicKey ||
          freshNode.fingerprint != stored.node.fingerprint) {
        throw const LoomProtocolException(
          'Pinned Home Node cryptographic identity changed',
        );
      }
      if (freshEndpoint.authority.toLowerCase() !=
          stored.endpoint.authority.toLowerCase()) {
        throw const LoomProtocolException(
          'Pinned Home Node endpoint authority changed',
        );
      }
      await _nodeVerifier.verify(
        baseUri: freshEndpoint,
        expectedNodeId: stored.node.nodeId,
        expectedPublicKey: stored.node.publicKey,
      );
      final fresh = LoomStoredSession(
        endpoint: freshEndpoint,
        node: freshNode,
        liveInfo: freshLiveInfo,
        receipt: stored.receipt,
      );
      if (!_isCurrent(epoch)) {
        throw StateError('Session changed');
      }
      await _sessionVault.write(fresh);
      return fresh;
    } catch (_) {
      if (_isCurrent(epoch)) {
        nodes.restoreTrustedSelection(
          node: stored.node,
          endpoint: stored.endpoint,
          liveInfo: stored.liveInfo,
        );
      }
      rethrow;
    }
  }

  Future<void> _challengeSelectedNode() async {
    final node = nodes.selectedNode;
    final endpoint = nodes.selectedEndpoint;
    if (!nodes.selectedNodeVerified || node == null || endpoint == null) {
      throw const LoomProtocolException(
        'Home Node must be freshly verified before credentials are sent',
      );
    }
    await _nodeVerifier.verify(
      baseUri: endpoint,
      expectedNodeId: node.nodeId,
      expectedPublicKey: node.publicKey,
    );
  }

  Future<void> _publishDeviceSecurity({
    required LoomIdentityPublic identity,
    required LoomRegistrationReceipt receipt,
    required String token,
    required int epoch,
  }) async {
    if (!_isCurrent(epoch)) throw StateError('Session changed');
    final endpoint = nodes.selectedEndpoint;
    if (!nodes.selectedNodeVerified || endpoint == null) {
      throw const LoomProtocolException(
        'A freshly verified Home Node is required to publish device keys',
      );
    }
    final bundle = await _deviceSecurityCore.createOrLoadDevice(
      identity: identity,
      deviceId: receipt.deviceId,
      deviceName: 'Loom ${Platform.operatingSystem}',
      identitySigner: _identityCore,
    );
    if (!_isCurrent(epoch)) throw StateError('Session changed');
    if (bundle.identityId != identity.identityId ||
        bundle.deviceId != receipt.deviceId) {
      throw const LoomProtocolException('Local device-key binding mismatch');
    }
    final proofProvider = await _deviceProofProviderFor(
      identity: identity,
      currentReceipt: receipt,
    );
    if (!_isCurrent(epoch)) throw StateError('Session changed');
    await _securityClient.publishDeviceBundle(
      baseUri: endpoint,
      accessToken: token,
      bundle: bundle,
      deviceProofProvider: proofProvider,
    );
  }

  void resetPending() {
    _sessionEpoch++;
    _restoreFuture = null;
    _storedSession = null;
    _restoreAttempted = true;
    _identityCore.discardPendingIdentity();
    pendingIdentity = null;
    committedIdentity = null;
    receipt = null;
    accessToken = null;
    accessTokenExpiresAt = null;
    errorMessage = null;
    username = '';
    displayName = '';
    password = '';
    status = LoomOnboardingStatus.idle;
    notifyListeners();
  }

  /// Activates a QR-linked password-authenticated session after the identity
  /// transfer and fresh device-key publication have both succeeded.
  void completeLinkedSession({
    required LoomIdentityPublic identity,
    required LoomLoginResult login,
    required LoomStoredSession storedSession,
    required String username,
  }) {
    if (_disposed || LoomAppLock.instance.locked) {
      throw StateError('Loom is locked');
    }
    _sessionEpoch++;
    if (login.identityId != identity.identityId ||
        storedSession.receipt.accountId != login.receipt.accountId ||
        storedSession.receipt.deviceId != login.receipt.deviceId ||
        storedSession.receipt.address.toLowerCase() !=
            login.receipt.address.toLowerCase()) {
      throw StateError('Linked session identity or device binding mismatch');
    }
    _identityCore.discardPendingIdentity();
    pendingIdentity = null;
    _storedSession = storedSession;
    committedIdentity = identity;
    receipt = login.receipt;
    accessToken = login.accessToken;
    accessTokenExpiresAt = DateTime.now().toUtc().add(
      Duration(seconds: login.accessTokenExpiresInSeconds),
    );
    this.username = username.trim().toLowerCase();
    password = '';
    errorMessage = null;
    status = LoomOnboardingStatus.complete;
    notifyListeners();
  }

  Future<bool> signIn({
    required String nodeDomain,
    required String username,
    required String password,
  }) async {
    if (_disposed ||
        _preparingIdentity ||
        LoomAppLock.instance.locked ||
        status == LoomOnboardingStatus.creatingIdentity ||
        status == LoomOnboardingStatus.registering) {
      return false;
    }
    final epoch = ++_sessionEpoch;
    status = LoomOnboardingStatus.registering;
    errorMessage = null;
    notifyListeners();
    try {
      // Recovery may repair this identity, but these global vaults have no
      // transaction for replacing another identity and its session/device keys.
      // Validate before discovery or authentication, not after writing secrets.
      final pending = pendingIdentity;
      final validatedPending = pending == null
          ? null
          : await _validatePendingIdentity(pending);
      final identity =
          validatedPending?.identity ??
          committedIdentity ??
          await _identityCore.readIdentity();
      if (identity == null) {
        throw const LoomProtocolException(
          'Restore your 24-word identity before signing in on this device',
        );
      }
      if (!_isCurrent(epoch)) return false;
      await nodes.discoverAndSelectDomain(nodeDomain);
      if (!_isCurrent(epoch)) return false;
      final endpoint = nodes.selectedEndpoint;
      if (!nodes.selectedNodeVerified || endpoint == null) {
        throw LoomProtocolException(
          nodes.errorMessage ?? 'The Home Node could not be verified',
        );
      }
      await _challengeSelectedNode();
      if (!_isCurrent(epoch)) return false;
      final result = await _nodeClient.login(
        baseUri: endpoint,
        username: username,
        password: password,
      );
      if (!_isCurrent(epoch)) {
        return false;
      }
      if (result.identityId != identity.identityId) {
        throw const LoomProtocolException(
          'This Node account belongs to a different Loom identity',
        );
      }
      if (validatedPending != null) {
        await _identityCore.commitPendingIdentity(validatedPending);
        if (!_isCurrent(epoch)) return false;
        pendingIdentity = null;
        committedIdentity = identity;
      }
      await _publishDeviceSecurity(
        identity: identity,
        receipt: result.receipt,
        token: result.accessToken,
        epoch: epoch,
      );
      if (!_isCurrent(epoch)) {
        return false;
      }
      await _credentialVault.writeRefreshToken(
        homeNode: result.receipt.homeNode,
        deviceId: result.receipt.deviceId,
        refreshToken: result.refreshToken,
      );
      if (!_isCurrent(epoch)) {
        return false;
      }
      committedIdentity = identity;
      receipt = result.receipt;
      accessToken = result.accessToken;
      accessTokenExpiresAt = DateTime.now().toUtc().add(
        Duration(seconds: result.accessTokenExpiresInSeconds),
      );
      this.username = username.trim().toLowerCase();
      this.password = '';
      try {
        await _persistSession(result.receipt, epoch: epoch);
      } catch (error) {
        if (!_isCurrent(epoch)) return false;
        errorMessage =
            'Signed in, but this device could not save automatic sign-in: $error';
      }
      if (!_isCurrent(epoch)) return false;
      status = LoomOnboardingStatus.complete;
      notifyListeners();
      return true;
    } catch (error) {
      if (!_isCurrent(epoch)) {
        return false;
      }
      final message = error is LoomProtocolException
          ? error.message
          : error.toString();
      errorMessage = message == 'invalid_credentials'
          ? 'The username or password is incorrect.'
          : message;
      status = LoomOnboardingStatus.error;
      notifyListeners();
      return false;
    }
  }

  Future<bool> createIdentity({
    required String username,
    required String displayName,
    required String password,
  }) async {
    if (_disposed ||
        _preparingIdentity ||
        LoomAppLock.instance.locked ||
        status == LoomOnboardingStatus.creatingIdentity ||
        status == LoomOnboardingStatus.registering) {
      return false;
    }
    final epoch = _sessionEpoch;
    errorMessage = null;
    if (!nodes.selectedNodeVerified) {
      errorMessage = 'Choose and verify a Node before creating an identity.';
      status = LoomOnboardingStatus.error;
      notifyListeners();
      return false;
    }
    final normalized = username.trim().toLowerCase();
    if (!RegExp(r'^[a-z0-9_][a-z0-9_.-]{2,31}$').hasMatch(normalized)) {
      errorMessage =
          'Username must be 3–32 characters using lowercase letters, numbers, _, . or -.';
      status = LoomOnboardingStatus.error;
      notifyListeners();
      return false;
    }
    if (displayName.trim().isEmpty || displayName.trim().length > 80) {
      errorMessage = 'Display name must be 1–80 characters.';
      status = LoomOnboardingStatus.error;
      notifyListeners();
      return false;
    }
    if (password.length < 12 || password.length > 256) {
      errorMessage = 'Password must be at least 12 characters.';
      status = LoomOnboardingStatus.error;
      notifyListeners();
      return false;
    }
    _preparingIdentity = true;
    status = LoomOnboardingStatus.creatingIdentity;
    notifyListeners();
    try {
      this.username = normalized;
      this.displayName = displayName.trim();
      this.password = password;
      final pending = await _identityCore.createIdentity();
      if (!_isCurrent(epoch)) {
        _identityCore.discardPendingIdentity();
        return false;
      }
      pendingIdentity = pending;
      status = LoomOnboardingStatus.recoveryReady;
      notifyListeners();
      return true;
    } catch (error) {
      if (!_isCurrent(epoch)) {
        _identityCore.discardPendingIdentity();
        return false;
      }
      errorMessage = error.toString();
      status = LoomOnboardingStatus.error;
      notifyListeners();
      return false;
    } finally {
      _preparingIdentity = false;
    }
  }

  Future<bool> restoreIdentityWords(String sentence) async {
    if (_disposed ||
        _preparingIdentity ||
        LoomAppLock.instance.locked ||
        status == LoomOnboardingStatus.creatingIdentity ||
        status == LoomOnboardingStatus.registering) {
      return false;
    }
    final epoch = _sessionEpoch;
    errorMessage = null;
    final words = sentence
        .trim()
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.length != 24) {
      errorMessage = 'Loom Identity v1 recovery requires exactly 24 words.';
      status = LoomOnboardingStatus.error;
      notifyListeners();
      return false;
    }
    _preparingIdentity = true;
    status = LoomOnboardingStatus.creatingIdentity;
    notifyListeners();
    try {
      _identityCore.discardPendingIdentity();
      pendingIdentity = null;
      final pending = await _identityCore.restoreIdentityFromWords(words);
      final validated = await _validatePendingIdentity(pending);
      if (!_isCurrent(epoch)) {
        _identityCore.discardPendingIdentity();
        return false;
      }
      pendingIdentity = validated;
      status = LoomOnboardingStatus.recoveryReady;
      notifyListeners();
      return true;
    } catch (error) {
      _identityCore.discardPendingIdentity();
      pendingIdentity = null;
      if (!_isCurrent(epoch)) return false;
      errorMessage = error is LoomProtocolException
          ? error.message
          : 'Could not validate the recovery backup. Check the original 24 words and try again after unlocking.';
      status = LoomOnboardingStatus.error;
      notifyListeners();
      return false;
    } finally {
      _preparingIdentity = false;
    }
  }

  Future<LoomPendingIdentity> _validatePendingIdentity(
    LoomPendingIdentity pending,
  ) async {
    final stored = await _identityCore.readIdentity();
    for (final existing in [committedIdentity, stored]) {
      if (existing != null &&
          (existing.identityId != pending.identity.identityId ||
              existing.publicKey != pending.identity.publicKey)) {
        throw const LoomProtocolException(
          'This device already holds a different Loom identity. '
          'It cannot be replaced safely here. Restore this backup on another '
          'device or installation, and keep the current account backup.',
        );
      }
    }
    // Derivation timestamps describe this restore attempt. Keep the original
    // public metadata when repairing the same identity's signing material.
    return LoomPendingIdentity(
      identity: stored ?? committedIdentity ?? pending.identity,
      recovery: pending.recovery,
    );
  }

  bool verifyRecoveryWord(int oneBasedIndex, String value) {
    final words = pendingIdentity?.recovery.mnemonicWords;
    if (words == null || oneBasedIndex < 1 || oneBasedIndex > words.length) {
      return false;
    }
    return words[oneBasedIndex - 1].toLowerCase() == value.trim().toLowerCase();
  }

  Future<bool> commitAndRegister() async {
    if (_disposed ||
        _preparingIdentity ||
        LoomAppLock.instance.locked ||
        status == LoomOnboardingStatus.creatingIdentity ||
        status == LoomOnboardingStatus.registering) {
      return false;
    }
    final pending = pendingIdentity;
    final endpoint = nodes.selectedEndpoint;
    if (pending == null || endpoint == null) {
      // A silent `false` dead-ends the recovery-verification screen; the
      // session was likely cleared by an app lock mid-setup. Surface it.
      errorMessage = pending == null
          ? 'Setup state expired while locked. Please start identity setup again.'
          : 'Choose a Node before finishing setup.';
      notifyListeners();
      return false;
    }
    final epoch = ++_sessionEpoch;
    status = LoomOnboardingStatus.registering;
    errorMessage = null;
    notifyListeners();
    LoomRegistrationResult? result;
    try {
      final validatedPending = await _validatePendingIdentity(pending);
      if (!_isCurrent(epoch)) return false;
      await _challengeSelectedNode();
      if (!_isCurrent(epoch)) return false;
      result = await _nodeClient.registerIdentity(
        baseUri: endpoint,
        username: username,
        displayName: displayName,
        password: password,
        identity: validatedPending.identity,
        deviceName: 'Loom ${Platform.operatingSystem}',
      );
      if (!_isCurrent(epoch)) return false;
      await _identityCore.commitPendingIdentity(validatedPending);
      if (!_isCurrent(epoch)) return false;
      committedIdentity = validatedPending.identity;
      pendingIdentity = null;
      password = '';
      await _publishDeviceSecurity(
        identity: validatedPending.identity,
        receipt: result.receipt,
        token: result.accessToken,
        epoch: epoch,
      );
      if (!_isCurrent(epoch)) return false;
      await _credentialVault.writeRefreshToken(
        homeNode: result.receipt.homeNode,
        deviceId: result.receipt.deviceId,
        refreshToken: result.refreshToken,
      );
      if (!_isCurrent(epoch)) return false;
      receipt = result.receipt;
      accessToken = result.accessToken;
      accessTokenExpiresAt = DateTime.now().toUtc().add(
        Duration(seconds: result.accessTokenExpiresInSeconds),
      );
      try {
        await _persistSession(result.receipt, epoch: epoch);
      } catch (error) {
        if (!_isCurrent(epoch)) return false;
        errorMessage =
            'Account created, but this device could not save automatic sign-in: $error';
      }
      if (!_isCurrent(epoch)) return false;
      status = LoomOnboardingStatus.complete;
      notifyListeners();
      return true;
    } catch (error) {
      if (!_isCurrent(epoch)) return false;
      if (result != null && committedIdentity != null) {
        errorMessage =
            'The account and identity were created, but secure device-key setup failed. '
            'Sign in again on this device to finish security setup. ${_friendlyRegistrationError(error)}';
      } else {
        errorMessage = _friendlyRegistrationError(error);
      }
      status = LoomOnboardingStatus.error;
      notifyListeners();
      return false;
    }
  }

  Future<void> _persistSession(
    LoomRegistrationReceipt currentReceipt, {
    required int epoch,
  }) async {
    if (!_isCurrent(epoch)) throw StateError('Session changed');
    final selectedNode = nodes.selectedNode;
    final selectedEndpoint = nodes.selectedEndpoint;
    final selectedLiveInfo = nodes.selectedLiveInfo;
    if (!nodes.selectedNodeVerified ||
        selectedNode == null ||
        selectedEndpoint == null ||
        selectedLiveInfo == null) {
      throw StateError('Freshly verified Home Node metadata is unavailable');
    }
    final stored = LoomStoredSession(
      endpoint: selectedEndpoint,
      node: selectedNode,
      liveInfo: selectedLiveInfo,
      receipt: currentReceipt,
    );
    await _sessionVault.write(stored);
    if (!_isCurrent(epoch)) throw StateError('Session changed');
    _storedSession = stored;
  }

  String _friendlyRegistrationError(Object error) {
    final message = error is LoomProtocolException
        ? error.message
        : error.toString();
    return switch (message) {
      'username_taken' =>
        'This username is already registered on this Node. Use Restore identity or choose another username.',
      'identity_already_registered' =>
        'This Loom account already exists on this Node. Use Restore identity or sign in instead.',
      'registration_requires_approval' =>
        'This Node requires operator approval before an account can be created.',
      'registration_closed' => 'Account registration is closed on this Node.',
      _ => message,
    };
  }

  @override
  void dispose() {
    _disposed = true;
    clearTransientSecrets();
    super.dispose();
  }
}

class LoomOnboardingScope extends InheritedNotifier<LoomOnboardingController> {
  const LoomOnboardingScope({
    required LoomOnboardingController controller,
    required super.child,
    super.key,
  }) : super(notifier: controller);

  static LoomOnboardingController of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<LoomOnboardingScope>();
    assert(scope != null, 'LoomOnboardingScope not found');
    return scope!.notifier!;
  }
}
