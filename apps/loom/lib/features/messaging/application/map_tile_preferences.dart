import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Which basemap the in-chat maps render from. The source is a runtime
/// client-side preference; nothing about it is security-sensitive.
enum LoomMapTileProvider { osm, snappmaps, carto, server, custom }

/// A fully resolved tile source: light and dark XYZ templates plus the
/// attribution text shown by the map widget.
class LoomMapTileSource {
  const LoomMapTileSource({
    required this.provider,
    required this.urlTemplate,
    required this.attribution,
    this.darkUrlTemplate,
    this.invertInDark = false,
  });

  final LoomMapTileProvider provider;
  final String urlTemplate;
  final String? darkUrlTemplate;
  final String attribution;
  final bool invertInDark;
}

/// Runtime-selectable basemap source for location previews and the map
/// viewer. Persisted as plain JSON in the app-support directory (like the
/// appearance preferences), because tile choice is not sensitive and must be
/// readable before any vault unlock.
///
/// Providers:
///  - osm: the OpenStreetMap standard raster tiles (default, no key).
///  - snappmaps: the Snapp Maps XYZ raster tiles (Persian labels, no key).
///  - carto: CARTO basemaps with a real dark variant; needs an operator key.
///  - server: tiles served by the user's own Home Node (`/tiles` cache).
///  - custom: any user-supplied XYZ `{z}/{x}/{y}` template.
class LoomMapTilePreferences extends ChangeNotifier {
  LoomMapTilePreferences._();

  static final LoomMapTilePreferences instance = LoomMapTilePreferences._();

  static const _fileName = 'loom-map-tiles.json';

  LoomMapTileProvider _provider = LoomMapTileProvider.osm;
  String _customTemplate = '';
  String _serverTemplate = '';
  String _cartoApiKey = '';
  bool _loaded = false;

  LoomMapTileProvider get provider => _provider;

  /// User-supplied `{z}/{x}/{y}` template for the custom provider.
  String get customTemplate => _customTemplate;

  /// Template pointing at the user's own Home Node tile cache, e.g.
  /// `https://node.example.org/tiles/{z}/{x}/{y}.png`.
  String get serverTemplate => _serverTemplate;

  String get cartoApiKey => _cartoApiKey;

  Future<void> _writes = Future<void>.value();
  Directory? _directory;

  /// Test seam: persist into an isolated directory.
  @visibleForTesting
  void useDirectory(Directory directory) => _directory = directory;

  Future<File> _file() async {
    final support = _directory ?? await getApplicationSupportDirectory();
    return File('${support.path}/$_fileName');
  }

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    // Builds that shipped with a compile-time CARTO key keep using it until
    // the user picks a source explicitly in the Maps settings.
    const compileTimeCartoKey = String.fromEnvironment(
      'LOOM_CARTO_BASEMAP_KEY',
    );
    if (compileTimeCartoKey.isNotEmpty) {
      _provider = LoomMapTileProvider.carto;
      _cartoApiKey = compileTimeCartoKey;
    }
    try {
      final raw = await (await _file()).readAsString();
      final data = jsonDecode(raw);
      if (data is! Map<String, dynamic>) return;
      final saved = LoomMapTileProvider.values
          .where((value) => value.name == data['provider'])
          .firstOrNull;
      if (saved != null) _provider = saved;
      if (data['customTemplate'] is String) {
        _customTemplate = data['customTemplate'] as String;
      }
      if (data['serverTemplate'] is String) {
        _serverTemplate = data['serverTemplate'] as String;
      }
      if (data['cartoApiKey'] is String) {
        _cartoApiKey = data['cartoApiKey'] as String;
      }
    } catch (_) {
      // Missing or corrupted preferences fall back to the OSM default.
    }
  }

  Future<void> _persist() {
    final captured = {
      'provider': _provider.name,
      'customTemplate': _customTemplate,
      'serverTemplate': _serverTemplate,
      'cartoApiKey': _cartoApiKey,
    };
    return _writes = _writes.then((_) async {
      try {
        await (await _file()).writeAsString(jsonEncode(captured));
      } catch (_) {
        // Preference persistence is best effort.
      }
    });
  }

  void select(LoomMapTileProvider value) {
    if (_provider == value) return;
    _provider = value;
    notifyListeners();
    unawaited(_persist());
  }

  void updateCustomTemplate(String value) {
    final trimmed = value.trim();
    if (_customTemplate == trimmed) return;
    _customTemplate = trimmed;
    notifyListeners();
    unawaited(_persist());
  }

  void updateServerTemplate(String value) {
    final trimmed = value.trim();
    if (_serverTemplate == trimmed) return;
    _serverTemplate = trimmed;
    notifyListeners();
    unawaited(_persist());
  }

  void updateCartoApiKey(String value) {
    final trimmed = value.trim();
    if (_cartoApiKey == trimmed) return;
    _cartoApiKey = trimmed;
    notifyListeners();
    unawaited(_persist());
  }

  /// Resolves the currently selected provider into concrete templates.
  /// Falls back to OpenStreetMap when a custom/server template is missing or
  /// malformed.
  LoomMapTileSource resolve({bool dark = false}) {
    switch (_provider) {
      case LoomMapTileProvider.osm:
        return const LoomMapTileSource(
          provider: LoomMapTileProvider.osm,
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          attribution: '© OpenStreetMap contributors',
          invertInDark: true,
        );
      case LoomMapTileProvider.snappmaps:
        return const LoomMapTileSource(
          provider: LoomMapTileProvider.snappmaps,
          urlTemplate: 'https://tile.snappmaps.ir/{z}/{x}/{y}.png',
          attribution: '© Snapp Maps · OpenStreetMap contributors',
          invertInDark: true,
        );
      case LoomMapTileProvider.carto:
        final key = Uri.encodeComponent(_cartoApiKey);
        return LoomMapTileSource(
          provider: LoomMapTileProvider.carto,
          urlTemplate:
              'https://a.basemaps.cartocdn.com/rastertiles/voyager'
              '/{z}/{x}/{y}.png${_cartoApiKey.isEmpty ? '' : '?key=$key'}',
          darkUrlTemplate:
              'https://a.basemaps.cartocdn.com/dark_all'
              '/{z}/{x}/{y}.png${_cartoApiKey.isEmpty ? '' : '?key=$key'}',
          attribution: '© CARTO · OpenStreetMap contributors',
        );
      case LoomMapTileProvider.server:
        final template = _serverTemplate;
        if (!_isTemplate(template)) return _osmFallback;
        return LoomMapTileSource(
          provider: LoomMapTileProvider.server,
          urlTemplate: template,
          attribution: 'Loom Home Node tile cache',
          invertInDark: true,
        );
      case LoomMapTileProvider.custom:
        final template = _customTemplate;
        if (!_isTemplate(template)) return _osmFallback;
        return LoomMapTileSource(
          provider: LoomMapTileProvider.custom,
          urlTemplate: template,
          attribution: 'Custom basemap',
          invertInDark: true,
        );
    }
  }

  static const _osmFallback = LoomMapTileSource(
    provider: LoomMapTileProvider.osm,
    urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
    attribution: '© OpenStreetMap contributors',
    invertInDark: true,
  );

  static bool _isTemplate(String template) =>
      template.startsWith(RegExp(r'https?://')) &&
      template.contains('{z}') &&
      template.contains('{x}') &&
      template.contains('{y}') &&
      template.length <= 512;
}
