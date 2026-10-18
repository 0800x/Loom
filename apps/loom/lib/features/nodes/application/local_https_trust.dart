import 'dart:io';
import 'dart:typed_data';
import 'package:loom_transport/loom_transport.dart';
import 'package:path_provider/path_provider.dart';

class LoomLocalHttpsTrust {
  static final _policy = LoomScopedCertificatePolicy();
  static String origin(Uri endpoint) =>
      LoomScopedCertificatePolicy.origin(endpoint);
  static const maximumBytes = LoomScopedCertificatePolicy.maximumBytes;
  static Uint8List certificateDer(List<int> bytes) =>
      LoomScopedCertificatePolicy.certificateDer(bytes);
  static Future<String> fingerprint(List<int> bytes) async =>
      LoomScopedCertificatePolicy.fingerprint(bytes);
  static Future<Directory> _directory(Directory? value) async =>
      value ??
      Directory('${(await getApplicationSupportDirectory()).path}/local-https');
  static Future<void> accept(
    List<int> bytes, {
    required Uri endpoint,
    required String confirmedFingerprint,
    Directory? directory,
  }) async {
    await _policy.accept(
      bytes,
      endpoint: endpoint,
      confirmedFingerprint: confirmedFingerprint,
      directory: await _directory(directory),
    );
    HttpOverrides.global = _policy;
  }

  static Future<int> load({Directory? directory}) async {
    final rejected = await _policy.load(await _directory(directory));
    HttpOverrides.global = _policy;
    return rejected;
  }

  static Future<List<String>> fingerprints({Directory? directory}) async =>
      _policy.fingerprints(await _directory(directory));
  static Future<void> forget(
    String fingerprint, {
    Directory? directory,
  }) async =>
      _policy.forgetFingerprint(fingerprint, await _directory(directory));
  static Future<void> forgetHost(Uri endpoint, {Directory? directory}) async =>
      _policy.forgetHost(endpoint, await _directory(directory));
}
