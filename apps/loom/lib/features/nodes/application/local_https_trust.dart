import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:path_provider/path_provider.dart';

/// Public certificates explicitly accepted by the device owner. This never
/// accepts a failed handshake or installs a certificate fetched from the node.
class LoomLocalHttpsTrust {
  static const maximumBytes = 65536;

  static List<int> certificateDer(List<int> bytes) {
    if (bytes.isEmpty || bytes.length > maximumBytes) {
      throw const FormatException('Select one public PEM certificate.');
    }
    final text = utf8.decode(bytes);
    final match = RegExp(
      r'^\s*-----BEGIN CERTIFICATE-----\s*([A-Za-z0-9+/=\s]+)\s*-----END CERTIFICATE-----\s*$',
    ).firstMatch(text);
    if (match == null) {
      throw const FormatException(
        'Select one public PEM certificate, without private keys.',
      );
    }
    return base64.decode(match.group(1)!.replaceAll(RegExp(r'\s'), ''));
  }

  static Future<String> fingerprint(List<int> bytes) async {
    final digest = await Sha256().hash(certificateDer(bytes));
    return digest.bytes
        .map((value) => value.toRadixString(16).padLeft(2, '0').toUpperCase())
        .join(':');
  }

  static Future<Directory> _directory(Directory? directory) async =>
      directory ??
      Directory('${(await getApplicationSupportDirectory()).path}/local-https');

  static void _install(List<int> bytes, SecurityContext context) {
    final der = certificateDer(bytes);
    context.setTrustedCertificatesBytes(Platform.isIOS ? der : bytes);
  }

  static Future<void> accept(
    List<int> bytes, {
    Directory? directory,
    SecurityContext? context,
  }) async {
    // Parse X509 before persisting anything. No badCertificateCallback is used.
    _install(bytes, SecurityContext());
    final digest = (await fingerprint(bytes)).replaceAll(':', '').toLowerCase();
    final folder = await _directory(directory);
    await folder.create(recursive: true);
    final staged = File('${folder.path}/$digest.pending');
    await staged.writeAsBytes(bytes, flush: true);
    await staged.rename('${folder.path}/$digest.pem');
    _install(bytes, context ?? SecurityContext.defaultContext);
  }

  static Future<List<String>> fingerprints({Directory? directory}) async {
    final folder = await _directory(directory);
    if (!await folder.exists()) return [];
    final result = <String>[];
    await for (final entry in folder.list(followLinks: false)) {
      if (entry is! File) continue;
      final name = entry.uri.pathSegments.last;
      if (!RegExp(r'^[a-f0-9]{64}\.pem$').hasMatch(name)) continue;
      final hex = name.substring(0, 64).toUpperCase();
      result.add(
        [
          for (var i = 0; i < hex.length; i += 2) hex.substring(i, i + 2),
        ].join(':'),
      );
    }
    result.sort();
    return result;
  }

  static Future<void> forget(String fingerprint, {Directory? directory}) async {
    final hex = fingerprint.replaceAll(':', '').toLowerCase();
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(hex)) {
      throw const FormatException('Invalid certificate fingerprint.');
    }
    final folder = await _directory(directory);
    final file = File('${folder.path}/$hex.pem');
    if (await file.exists()) await file.delete();
    // Existing TLS contexts are released when the user restarts Loom.
  }

  /// Called before constructing HTTP/WebSocket clients at application startup.
  /// Invalid files remain untrusted; they are never replaced with a TLS bypass.
  static Future<int> load({
    Directory? directory,
    SecurityContext? context,
  }) async {
    final folder = await _directory(directory);
    if (!await folder.exists()) return 0;
    var rejected = 0;
    await for (final entry in folder.list(followLinks: false)) {
      if (entry is! File || !entry.path.endsWith('.pem')) continue;
      try {
        if (await entry.length() > maximumBytes) {
          rejected++;
          continue;
        }
        final bytes = await entry.readAsBytes();
        final digest = (await fingerprint(
          bytes,
        )).replaceAll(':', '').toLowerCase();
        if (!entry.path.endsWith('/$digest.pem') &&
            !entry.path.endsWith('\\$digest.pem')) {
          rejected++;
          continue;
        }
        _install(bytes, context ?? SecurityContext.defaultContext);
      } catch (_) {
        rejected++;
      }
    }
    return rejected;
  }
}
