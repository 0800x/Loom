import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path_provider/path_provider.dart';
import 'package:loom_crypto_bridge/loom_crypto_bridge.dart';

class LoomAccountEntry {
  const LoomAccountEntry({
    required this.id,
    required this.label,
    this.address,
    this.legacy = false,
  });

  final String id;
  final String label;
  final String? address;
  final bool legacy;

  LoomAccountScope? get scope => legacy ? null : LoomAccountScope(id);

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'label': label,
    if (address != null) 'address': address,
    'legacy': legacy,
  };

  static LoomAccountEntry fromJson(Object? value) {
    if (value is! Map) throw const FormatException('Invalid account entry');
    final id = value['id'];
    final label = value['label'];
    final address = value['address'];
    final legacy = value['legacy'] == true;
    if (id is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{8,64}$').hasMatch(id) ||
        label is! String ||
        label.trim().isEmpty ||
        label.length > 80 ||
        (address != null && (address is! String || address.length > 512))) {
      throw const FormatException('Invalid account entry fields');
    }
    return LoomAccountEntry(
      id: id,
      label: label.trim(),
      address: address as String?,
      legacy: legacy,
    );
  }
}

class LoomAccountRegistryState {
  const LoomAccountRegistryState({
    required this.accounts,
    required this.activeId,
  });

  final List<LoomAccountEntry> accounts;
  final String? activeId;

  LoomAccountEntry? get active {
    for (final entry in accounts) {
      if (entry.id == activeId) return entry;
    }
    return null;
  }
}

/// Stores non-secret account labels and the active slot. Credentials remain in
/// platform secure storage, namespaced separately by [LoomAccountScope].
abstract final class LoomAccountRegistry {
  static const _fileName = 'loom-accounts.v1.json';

  static Future<File> _file() async {
    final root = await getApplicationSupportDirectory();
    await root.create(recursive: true);
    return File(root.path + Platform.pathSeparator + _fileName);
  }

  static Future<LoomAccountRegistryState> load() async {
    final file = await _file();
    if (!await file.exists()) {
      return const LoomAccountRegistryState(
        accounts: <LoomAccountEntry>[],
        activeId: null,
      );
    }
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map ||
        decoded['version'] != 1 ||
        decoded['accounts'] is! List ||
        (decoded['activeId'] != null && decoded['activeId'] is! String)) {
      throw const FormatException('Invalid Loom account registry');
    }
    final accounts = (decoded['accounts'] as List)
        .map(LoomAccountEntry.fromJson)
        .toList(growable: false);
    final ids = accounts.map((entry) => entry.id).toSet();
    if (ids.length != accounts.length ||
        (decoded['activeId'] != null && !ids.contains(decoded['activeId']))) {
      throw const FormatException('Inconsistent Loom account registry');
    }
    return LoomAccountRegistryState(
      accounts: List<LoomAccountEntry>.unmodifiable(accounts),
      activeId: decoded['activeId'] as String?,
    );
  }

  static Future<void> _save(LoomAccountRegistryState state) async {
    final file = await _file();
    final temporary = File(file.path + '.tmp');
    final json = jsonEncode(<String, Object?>{
      'version': 1,
      'activeId': state.activeId,
      'accounts': state.accounts.map((entry) => entry.toJson()).toList(),
    });
    final backup = File(file.path + '.bak');
    if (await backup.exists() && !await file.exists()) {
      await backup.rename(file.path);
    } else if (await backup.exists()) {
      await backup.delete();
    }

    await temporary.writeAsString(json, flush: true);
    if (await file.exists()) await file.rename(backup.path);
    try {
      await temporary.rename(file.path);
      if (await backup.exists()) await backup.delete();
    } catch (_) {
      if (!await file.exists() && await backup.exists()) {
        await backup.rename(file.path);
      }
      rethrow;
    }
  }

  static Future<LoomAccountScope?> activeScope() async {
    final state = await load();
    return state.active?.scope;
  }

  static Future<void> setActive(String id) async {
    final state = await load();
    if (!state.accounts.any((entry) => entry.id == id)) {
      throw StateError('The selected Loom account does not exist');
    }
    await _save(LoomAccountRegistryState(
      accounts: state.accounts,
      activeId: id,
    ));
  }

  static Future<void> updateEntry(
    String id, {
    String? label,
    String? address,
  }) async {
    final state = await load();
    var found = false;
    final accounts = state.accounts.map((entry) {
      if (entry.id != id) return entry;
      found = true;
      return LoomAccountEntry(
        id: entry.id,
        label: (label == null || label.trim().isEmpty)
            ? entry.label
            : label.trim().substring(0, label.trim().length.clamp(1, 80).toInt()),
        address: address ?? entry.address,
        legacy: entry.legacy,
      );
    }).toList(growable: false);
    if (!found) throw StateError('The Loom account does not exist');
    await _save(LoomAccountRegistryState(
      accounts: accounts,
      activeId: state.activeId,
    ));
  }

  static Future<void> ensureCurrentRegistered({
    required String label,
    String? address,
  }) async {
    final state = await load();
    final active = state.active;
    if (active != null) {
      await updateEntry(active.id, label: label, address: address);
      LoomAccountScope.current = active.scope;
      return;
    }
    final entry = LoomAccountEntry(
      id: _newId(),
      label: label.trim().isEmpty ? 'Account' : label.trim(),
      address: address,
      legacy: true,
    );
    await _save(LoomAccountRegistryState(
      accounts: <LoomAccountEntry>[...state.accounts, entry],
      activeId: entry.id,
    ));
    LoomAccountScope.current = entry.scope;
  }

  static Future<LoomAccountEntry> addAccount() async {
    final state = await load();
    final entry = LoomAccountEntry(
      id: _newId(),
      label: 'Account ' + (state.accounts.length + 1).toString(),
    );
    await _save(LoomAccountRegistryState(
      accounts: <LoomAccountEntry>[...state.accounts, entry],
      activeId: entry.id,
    ));
    return entry;
  }

  static String _newId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }
}
