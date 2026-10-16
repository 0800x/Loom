import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:path_provider/path_provider.dart';

/// Per-file AES-256-GCM. The fresh key is carried only inside the E2EE message.
class LoomEncryptedMedia {
  static const maxBytes = 128 * 1024 * 1024;
  static final _cipher = AesGcm.with256bits();
  static final _aad = utf8.encode('loom.media.v1');
  static const cacheLimit = 128 * 1024 * 1024;
  static Future<void> _cacheWrites = Future<void>.value();

  static Uri _trustedUri(Map<String, Object?> media, String senderHome) {
    final uri = Uri.parse(media['url'] as String);
    if (uri.scheme != 'https' ||
        uri.host.toLowerCase() != senderHome.toLowerCase() ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        !RegExp(r'^/api/v1/attachments/att_[a-f0-9]{64}$').hasMatch(uri.path) ||
        media['bytes'] is! int ||
        (media['bytes'] as int) < 1 ||
        (media['bytes'] as int) > maxBytes) {
      throw const FormatException('Untrusted media endpoint');
    }
    return uri;
  }

  static Future<File> _cacheFile(
    Uri uri,
    Future<Directory> Function()? temporaryDirectory,
  ) async {
    final temp = await (temporaryDirectory ?? getTemporaryDirectory)();
    final root = await Directory(
      '${temp.path}/loom_media_encrypted',
    ).create(recursive: true);
    final hash = await Sha256().hash(utf8.encode(uri.toString()));
    final name = hash.bytes
        .map((v) => v.toRadixString(16).padLeft(2, '0'))
        .join();
    return File('${root.path}/$name.enc');
  }

  /// Only ciphertext is kept on disk. The capability/key remains exclusively
  /// in the authenticated E2EE message. Cached bytes undergo the SAME endpoint,
  /// size and GCM checks as network bytes, including after app restarts.
  static Future<Uint8List?> readCached(
    Map<String, Object?> media,
    String senderHome, {
    Future<Directory> Function()? temporaryDirectory,
  }) async {
    final uri = _trustedUri(media, senderHome);
    final file = await _cacheFile(uri, temporaryDirectory);
    if (!await file.exists()) return null;
    try {
      final expected = media['bytes'] as int;
      if (await file.length() != expected + 28) {
        throw const FormatException('Invalid cached media size');
      }
      final bytes = await file.readAsBytes();
      final clear = await decrypt(bytes, media['key'] as String, expected);
      try {
        await file.setLastModified(DateTime.now());
      } catch (_) {}
      return clear;
    } catch (_) {
      try {
        await file.delete();
      } catch (_) {}
      return null; // A corrupt/stale cache can be fetched and verified again.
    }
  }

  static Future<void> cacheEncrypted(
    Map<String, Object?> media,
    Uint8List bytes,
    String senderHome, {
    Future<Directory> Function()? temporaryDirectory,
  }) {
    final uri = _trustedUri(media, senderHome);
    if (bytes.length != (media['bytes'] as int) + 28) {
      throw const FormatException('Invalid cache payload');
    }
    return _cacheWrites = _cacheWrites.catchError((Object _) {}).then((
      _,
    ) async {
      final file = await _cacheFile(uri, temporaryDirectory);
      final staging = File('${file.path}.tmp');
      try {
        await staging.writeAsBytes(bytes, flush: true);
        await staging.rename(file.path);
        final entries = <({File file, FileStat stat})>[];
        await for (final entry in file.parent.list()) {
          if (entry is File && entry.path.endsWith('.enc')) {
            entries.add((file: entry, stat: await entry.stat()));
          }
        }
        entries.sort((a, b) => a.stat.modified.compareTo(b.stat.modified));
        var total = entries.fold<int>(0, (sum, e) => sum + e.stat.size);
        for (final entry in entries) {
          if (total <= cacheLimit) break;
          await entry.file.delete();
          total -= entry.stat.size;
        }
      } finally {
        if (await staging.exists()) await staging.delete();
      }
    });
  }

  static Future<({Uint8List bytes, String key})> encrypt(
    Uint8List clear,
  ) async {
    if (clear.isEmpty || clear.length > maxBytes) {
      throw const FormatException('Media size limit');
    }
    if (clear.length >= 256 * 1024) {
      final transfer = TransferableTypedData.fromList([clear]);
      final result = await Isolate.run(() => _encryptTransferred(transfer));
      return (bytes: result.bytes.materialize().asUint8List(), key: result.key);
    }
    return _encryptInline(clear);
  }

  static Future<({TransferableTypedData bytes, String key})>
  _encryptTransferred(TransferableTypedData transfer) async {
    final clear = transfer.materialize().asUint8List();
    try {
      final result = await _encryptInline(clear);
      return (
        bytes: TransferableTypedData.fromList([result.bytes]),
        key: result.key,
      );
    } finally {
      clear.fillRange(0, clear.length, 0);
    }
  }

  static Future<({Uint8List bytes, String key})> _encryptInline(
    Uint8List clear,
  ) async {
    final key = await _cipher.newSecretKey();
    final box = await _cipher.encrypt(clear, secretKey: key, aad: _aad);
    return (
      bytes: Uint8List.fromList(box.concatenation()),
      key: base64UrlEncode(await key.extractBytes()),
    );
  }

  static Future<Uint8List> decrypt(
    Uint8List bytes,
    String encodedKey,
    int expectedBytes,
  ) async {
    if (bytes.length >= 256 * 1024) {
      final transfer = TransferableTypedData.fromList([bytes]);
      final result = await Isolate.run(
        () => _decryptTransferred(transfer, encodedKey, expectedBytes),
      );
      return result.materialize().asUint8List();
    }
    return _decryptInline(bytes, encodedKey, expectedBytes);
  }

  static Future<TransferableTypedData> _decryptTransferred(
    TransferableTypedData transfer,
    String key,
    int expected,
  ) async {
    final clear = await _decryptInline(
      transfer.materialize().asUint8List(),
      key,
      expected,
    );
    try {
      return TransferableTypedData.fromList([clear]);
    } finally {
      clear.fillRange(0, clear.length, 0);
    }
  }

  static Future<Uint8List> _decryptInline(
    Uint8List bytes,
    String encodedKey,
    int expectedBytes,
  ) async {
    final key = base64Url.decode(encodedKey);
    if (key.length != 32 ||
        expectedBytes < 1 ||
        expectedBytes > maxBytes ||
        bytes.length != expectedBytes + 28) {
      throw const FormatException('Invalid encrypted media size');
    }
    final clear = await _cipher.decrypt(
      SecretBox.fromConcatenation(bytes, nonceLength: 12, macLength: 16),
      secretKey: SecretKey(key),
      aad: _aad,
    );
    return Uint8List.fromList(clear);
  }

  /// The encrypted capability is never passed to a third-party viewer. Do not
  /// forward account credentials across nodes or follow redirects from a peer.
  static Future<Uint8List> download(
    Map<String, Object?> media,
    String senderHome, {
    void Function(int received, int total)? onProgress,
    void Function()? onPreparing,
    bool Function()? cancelled,
    Future<Directory> Function()? temporaryDirectory,
  }) async {
    final uri = _trustedUri(media, senderHome);
    if (cancelled?.call() == true) throw StateError('Media cancelled');
    final cached = await readCached(
      media,
      senderHome,
      temporaryDirectory: temporaryDirectory,
    );
    if (cached != null) {
      if (cancelled?.call() == true) {
        cached.fillRange(0, cached.length, 0);
        throw StateError('Media cancelled');
      }
      return cached;
    }
    final expected = media['bytes'] as int;
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      return await (() async {
        final request = await client.getUrl(uri);
        request.followRedirects = false;
        final response = await request.close();
        if (response.statusCode != 200 ||
            (response.contentLength != -1 &&
                response.contentLength != expected + 28)) {
          throw const FormatException('Media download failed');
        }
        final chunks = BytesBuilder(copy: false);
        await for (final chunk in response) {
          if (cancelled?.call() == true) throw StateError('Media cancelled');
          chunks.add(chunk);
          if (chunks.length > expected + 28) {
            throw const FormatException('Media exceeds limit');
          }
          onProgress?.call(chunks.length, expected + 28);
        }
        onPreparing?.call();
        final encrypted = chunks.takeBytes();
        final clear = await decrypt(
          encrypted,
          media['key'] as String,
          expected,
        );
        if (cancelled?.call() == true) {
          clear.fillRange(0, clear.length, 0);
          throw StateError('Media cancelled');
        }
        try {
          await cacheEncrypted(
            media,
            encrypted,
            senderHome,
            temporaryDirectory: temporaryDirectory,
          );
        } catch (_) {}
        return clear;
      })().timeout(const Duration(minutes: 2));
    } finally {
      client.close(force: true);
    }
  }
}
