import 'dart:async';

import 'package:loom_models/loom_models.dart';
import 'package:loom_protocol/loom_protocol.dart';
import 'package:loom_storage/loom_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../../onboarding/application/onboarding_controller.dart';
import '../../profile/application/local_avatar_store.dart';

enum LoomPeopleState { idle, loading, ready, empty, error }

typedef LoomPeopleResolver =
    Future<LoomResolvedUserSecurity> Function({
      required Uri baseUri,
      required String accessToken,
      required String address,
      required LoomDeviceRequestProofProvider deviceProofProvider,
    });

class LoomResolvedPerson {
  const LoomResolvedPerson({
    required this.security,
    required this.username,
    required this.homeNode,
    required this.sameNode,
    required this.securityState,
  });

  final LoomResolvedUserSecurity security;
  final String username;
  final String homeNode;
  final bool sameNode;
  final LoomContactSecurityState securityState;

  String get canonicalAddress => security.address;
  String get displayName => security.displayName;
  String get identityId => security.identityId;
  bool get canMessage =>
      securityState != LoomContactSecurityState.changed &&
      security.devices.isNotEmpty;
}

class LoomPeopleController extends ChangeNotifier {
  LoomPeopleController({
    required this.homeNodeProvider,
    required this.endpointProvider,
    required this.accessTokenProvider,
    required this.deviceProofProvider,
    LoomPeopleResolver? resolver,
    LoomContactStore? contactStore,
  }) : _resolver = resolver ?? LoomDirectFirstUserSecurityResolver().resolve,
       _store = contactStore,
       _ownsStore = contactStore == null;

  factory LoomPeopleController.forOnboarding(
    LoomOnboardingController onboarding, {
    LoomPeopleResolver? resolver,
    LoomContactStore? contactStore,
  }) => LoomPeopleController(
    homeNodeProvider: () => onboarding.receipt?.homeNode,
    endpointProvider: () => onboarding.nodes.selectedEndpoint,
    accessTokenProvider: () async {
      final expiresAt = onboarding.accessTokenExpiresAt;
      if (onboarding.accessToken == null ||
          onboarding.accessToken!.isEmpty ||
          (expiresAt != null &&
              expiresAt.isBefore(
                DateTime.now().toUtc().add(const Duration(seconds: 30)),
              ))) {
        if (!await onboarding.refreshAccessToken()) {
          throw const LoomProtocolException('Access token unavailable');
        }
      }
      final token = onboarding.accessToken;
      if (token == null || token.isEmpty) {
        throw const LoomProtocolException('Access token unavailable');
      }
      return token;
    },
    deviceProofProvider: onboarding.deviceRequestProofProvider,
    resolver: resolver,
    contactStore: contactStore,
  );

  final String? Function() homeNodeProvider;
  final Uri? Function() endpointProvider;
  final Future<String> Function() accessTokenProvider;
  final Future<LoomDeviceRequestProofProvider> Function() deviceProofProvider;
  final LoomPeopleResolver _resolver;
  final bool _ownsStore;

  LoomContactStore? _store;
  LoomPeopleState state = LoomPeopleState.idle;
  List<LoomContact> contacts = const [];
  List<LoomResolvedPerson> results = const [];
  String? errorMessage;
  String? lastQuery;
  bool _opened = false;
  bool _disposed = false;
  int _searchGeneration = 0;
  Future<void>? _openFuture;

  Future<void> open() {
    if (_disposed || _opened) return Future.value();
    return _openFuture ??= _open().whenComplete(() => _openFuture = null);
  }

  Future<void> _open() async {
    try {
      if (_store == null) {
        final support = await getApplicationSupportDirectory();
        if (_disposed) return;
        _store = LoomContactStore.openFile(
          '${support.path}/loom-contacts-v1.sqlite3',
        );
      }
      _refreshContacts();
      _opened = true;
      state = LoomPeopleState.ready;
      notifyListeners();
    } catch (error) {
      if (_disposed) return;
      state = LoomPeopleState.error;
      errorMessage = _safeError(error);
      notifyListeners();
    }
  }

  void clearSearch() {
    if (_disposed) return;
    _searchGeneration++;
    results = const [];
    lastQuery = null;
    errorMessage = null;
    state = LoomPeopleState.ready;
    notifyListeners();
  }

  Future<void> search(String query) async {
    if (_disposed) return;
    if (query.trim().isEmpty) {
      clearSearch();
      return;
    }
    final generation = ++_searchGeneration;
    if (!_opened) await open();
    if (!_opened || _disposed || generation != _searchGeneration) return;

    final homeNode = homeNodeProvider();
    final endpoint = endpointProvider();
    lastQuery = query.trim();
    errorMessage = null;
    results = const [];
    if (homeNode == null || homeNode.trim().isEmpty || endpoint == null) {
      state = LoomPeopleState.error;
      errorMessage =
          'A verified Home Node session is required to search people.';
      notifyListeners();
      return;
    }

    LoomParsedAddress requested;
    try {
      requested = LoomAddress.normalizeInput(query, homeNode: homeNode);
    } on FormatException catch (error) {
      state = LoomPeopleState.error;
      errorMessage = error.message.toString();
      notifyListeners();
      return;
    }

    state = LoomPeopleState.loading;
    notifyListeners();
    try {
      final security = await _resolver(
        baseUri: endpoint,
        accessToken: await accessTokenProvider(),
        address: requested.canonical,
        deviceProofProvider: await deviceProofProvider(),
      ).timeout(const Duration(seconds: 20));
      if (_disposed || generation != _searchGeneration) return;
      final returned = LoomAddress.parseCanonical(security.address);
      if (returned.canonical != requested.canonical) {
        throw const LoomProtocolException(
          'Resolved address does not match the requested contact.',
        );
      }
      final existing = _store?.findByAddress(returned.canonical);
      final changed =
          existing != null && existing.identityId != security.identityId;
      final avatar = security.avatar;
      if (!changed && avatar != null) {
        unawaited(
          LoomLocalAvatarStore.forIdentity(security.identityId)
              .cachePeer(
                name: security.displayName,
                png: avatar.png,
                color: avatar.color,
              )
              .catchError((Object _) {}),
        );
      }
      final person = LoomResolvedPerson(
        security: security,
        username: returned.username,
        homeNode: returned.homeNode,
        sameNode: returned.isSameNode(homeNode),
        securityState: changed
            ? LoomContactSecurityState.changed
            : existing?.securityState ?? LoomContactSecurityState.resolved,
      );
      results = <LoomResolvedPerson>[person];
      state = LoomPeopleState.ready;
      notifyListeners();
    } catch (error) {
      if (_disposed || generation != _searchGeneration) return;
      final message = error is LoomProtocolException
          ? error.message
          : error.toString();
      if (message == 'user_not_found') {
        state = LoomPeopleState.empty;
        errorMessage = null;
      } else {
        state = LoomPeopleState.error;
        errorMessage = _friendlySearchError(message);
      }
      notifyListeners();
    }
  }

  bool isContact(String canonicalAddress) =>
      _store?.findByAddress(canonicalAddress) != null;

  bool addContact(LoomResolvedPerson person) {
    if (_disposed) return false;
    final store = _store;
    if (store == null) {
      errorMessage = 'Contacts storage is unavailable.';
      state = LoomPeopleState.error;
      notifyListeners();
      return false;
    }
    try {
      final existing = store.findByAddress(person.canonicalAddress);
      if (person.securityState == LoomContactSecurityState.changed ||
          (existing != null && existing.identityId != person.identityId)) {
        errorMessage =
            'This address now resolves to a different identity. Verify the identity change before replacing the saved contact.';
        state = LoomPeopleState.error;
        notifyListeners();
        return false;
      }
      final now = DateTime.now().toUtc();
      store.upsert(
        LoomContact(
          identityId: person.identityId,
          accountId: existing?.accountId,
          username: person.username,
          displayName: person.displayName,
          canonicalAddress: person.canonicalAddress,
          homeNode: person.homeNode,
          securityState: person.securityState,
          createdAt: existing?.createdAt ?? now,
          updatedAt: now,
          lastResolvedAt: now,
        ),
      );
      _refreshContacts();
      errorMessage = null;
      state = LoomPeopleState.ready;
      notifyListeners();
      return true;
    } catch (failure) {
      errorMessage = 'The contact could not be saved. Try again.';
      state = LoomPeopleState.error;
      notifyListeners();
      return false;
    }
  }

  void removeContact(String canonicalAddress) {
    _store?.delete(canonicalAddress);
    _refreshContacts();
    notifyListeners();
  }

  void _refreshContacts() {
    contacts = _store?.list() ?? const [];
  }

  String _friendlySearchError(String message) {
    if (message == 'federation_disabled') {
      return 'This Home Node has federation disabled, so remote users cannot be resolved.';
    }
    if (message.contains('federation_') ||
        message.contains('unreachable') ||
        message.contains('timed out') ||
        message.contains('SocketException')) {
      return 'The recipient Home Node could not be reached or verified. Check the address and try again.';
    }
    return _safeError(message);
  }

  String _safeError(Object error) {
    final value = error.toString().replaceAll(RegExp(r'[\r\n]+'), ' ').trim();
    return value.length <= 240 ? value : value.substring(0, 240);
  }

  @override
  void dispose() {
    _disposed = true;
    _searchGeneration++;
    if (_ownsStore) _store?.close();
    super.dispose();
  }
}
