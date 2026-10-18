import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:asn1lib/asn1lib.dart';
import 'package:crypto/crypto.dart' as crypto;

/// Exact leaf/HTTPS-origin pins. Never adds a root to defaultContext.
final class LoomScopedCertificatePolicy extends HttpOverrides {
  static const maximumBytes = 65536;
  final Map<String, String> _pins = {};
  final List<(WeakReference<HttpClient>, String)> _clients = [];

  static String origin(Uri endpoint) {
    if (endpoint.scheme != 'https' ||
        endpoint.host.isEmpty ||
        endpoint.userInfo.isNotEmpty ||
        endpoint.hasQuery ||
        endpoint.hasFragment ||
        (endpoint.path.isNotEmpty && endpoint.path != '/')) {
      throw const FormatException(
          'Enter one HTTPS server host and optional port.');
    }
    return Uri(
            scheme: 'https',
            host: endpoint.host.toLowerCase(),
            port: endpoint.port)
        .origin;
  }

  static Uint8List certificateDer(List<int> bytes) {
    if (bytes.isEmpty || bytes.length > maximumBytes)
      throw const FormatException('Select one public PEM certificate.');
    final match = RegExp(
            r'^\s*-----BEGIN CERTIFICATE-----\s*([A-Za-z0-9+/=\s]+)\s*-----END CERTIFICATE-----\s*$')
        .firstMatch(utf8.decode(bytes));
    if (match == null)
      throw const FormatException(
          'Select one public certificate, without private keys.');
    return base64.decode(match.group(1)!.replaceAll(RegExp(r'\s'), ''));
  }

  static String fingerprint(List<int> bytes) => crypto.sha256
      .convert(certificateDer(bytes))
      .bytes
      .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
      .join(':');

  static void validateLeaf(List<int> bytes) {
    try {
      final der = certificateDer(bytes);
      // Native X509 parsing validates the certificate structure in isolation.
      SecurityContext(withTrustedRoots: false)
          .setTrustedCertificatesBytes(Platform.isIOS ? der : bytes);
      final parser = ASN1Parser(der);
      final cert = parser.nextObject() as ASN1Sequence;
      if (parser.hasNext() || cert.elements.length != 3)
        throw const FormatException('Invalid X509 certificate');
      final tbs = cert.elements.first as ASN1Sequence;
      final extensionContainers =
          tbs.elements.where((e) => e.tag == 0xa3).toList();
      if (extensionContainers.length != 1)
        throw const FormatException('Explicit CA:FALSE is required.');
      final extensions = ASN1Parser(extensionContainers.single.valueBytes())
          .nextObject() as ASN1Sequence;
      var constraints = 0;
      for (final entry in extensions.elements) {
        final fields = (entry as ASN1Sequence).elements;
        if ((fields.first as ASN1ObjectIdentifier).identifier != '2.5.29.19')
          continue;
        constraints++;
        final value = fields.last as ASN1OctetString;
        final basic = ASN1Parser(value.octets).nextObject() as ASN1Sequence;
        // CA defaults to FALSE when omitted inside BasicConstraints.
        if (basic.elements.isNotEmpty &&
            basic.elements.first is ASN1Boolean &&
            (basic.elements.first as ASN1Boolean).booleanValue)
          throw const FormatException('CA certificates cannot be imported.');
      }
      if (constraints != 1)
        throw const FormatException('Explicit CA:FALSE is required.');
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('Invalid public leaf certificate.');
    }
  }

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.badCertificateCallback = (certificate, host, port) {
      final key = origin(Uri(scheme: 'https', host: host, port: port));
      final now = DateTime.now();
      if (now.isBefore(certificate.startValidity) ||
          now.isAfter(certificate.endValidity)) return false;
      final digest =
          crypto.sha256.convert(certificate.der).toString().toUpperCase();
      if (_pins[key]?.replaceAll(':', '') != digest) return false;
      _clients.removeWhere((entry) => entry.$1.target == null);
      if (!_clients.any(
          (entry) => identical(entry.$1.target, client) && entry.$2 == key)) {
        if (_clients.length >= 256) return false;
        _clients.add((WeakReference(client), key));
      }
      return true;
    };
    return client;
  }

  void _revoke(String key) {
    _pins.remove(key);
    for (final entry in _clients.where((entry) => entry.$2 == key)) {
      entry.$1.target?.close(force: true);
    }
    _clients.removeWhere((entry) => entry.$2 == key || entry.$1.target == null);
  }

  String _filename(String key) =>
      crypto.sha256.convert(utf8.encode(key)).toString();

  Future<void> accept(List<int> bytes,
      {required Uri endpoint,
      required String confirmedFingerprint,
      required Directory directory}) async {
    final key = origin(endpoint);
    validateLeaf(bytes);
    final digest = fingerprint(bytes);
    if (digest != confirmedFingerprint.toUpperCase())
      throw const FormatException('Fingerprint confirmation does not match.');
    await directory.create(recursive: true);
    final file = File('${directory.path}/${_filename(key)}.json');
    final staged = File('${file.path}.pending');
    await staged.writeAsString(
        jsonEncode(
            {'origin': key, 'fingerprint': digest, 'pem': utf8.decode(bytes)}),
        flush: true);
    await staged.rename(file.path);
    _revoke(key);
    _pins[key] = digest;
  }

  Future<int> load(Directory directory) async {
    for (final key in _pins.keys.toList()) {
      _revoke(key);
    }
    if (!await directory.exists()) return 0;
    var rejected = 0;
    await for (final entry in directory.list(followLinks: false)) {
      if (entry is! File || entry.path.endsWith('.pending')) continue;
      try {
        if (!entry.path.endsWith('.json') ||
            await entry.length() > 2 * maximumBytes)
          throw const FormatException('Unscoped or oversized trust file.');
        final data =
            jsonDecode(await entry.readAsString()) as Map<String, dynamic>;
        final key = origin(Uri.parse(data['origin'] as String));
        if (entry.uri.pathSegments.last != '${_filename(key)}.json')
          throw const FormatException('Trust binding mismatch.');
        final bytes = utf8.encode(data['pem'] as String);
        validateLeaf(bytes);
        final digest = fingerprint(bytes);
        if (digest != data['fingerprint'])
          throw const FormatException('Fingerprint mismatch.');
        _pins[key] = digest;
      } catch (_) {
        rejected++;
      }
    }
    return rejected;
  }

  Future<List<String>> fingerprints(Directory directory) async {
    // Loading also validates stored certificates and revokes stale contexts.
    await load(directory);
    return _pins.values.toSet().toList()..sort();
  }

  Future<void> forgetFingerprint(
      String fingerprint, Directory directory) async {
    if (!RegExp(r'^(?:[0-9A-Fa-f]{2}:){31}[0-9A-Fa-f]{2}$')
        .hasMatch(fingerprint))
      throw const FormatException('Invalid certificate fingerprint.');
    await load(directory);
    for (final key in _pins.keys
        .where((key) => _pins[key] == fingerprint.toUpperCase())
        .toList()) {
      await forgetHost(Uri.parse(key), directory);
    }
  }

  Future<void> forgetHost(Uri endpoint, Directory directory) async {
    final key = origin(endpoint);
    _revoke(key);
    final file = File('${directory.path}/${_filename(key)}.json');
    if (await file.exists()) await file.delete();
  }
}
