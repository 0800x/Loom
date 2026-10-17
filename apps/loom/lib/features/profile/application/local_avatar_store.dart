import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'avatar_photo.dart';

/// Durable per-identity profile cache and outbox. Network writes are explicit.
/// Each identity has a separate file, so switching accounts cannot reuse a photo.
class LoomLocalAvatarStore extends ChangeNotifier {
  LoomLocalAvatarStore(
    this.identityId, {
    Future<Directory> Function()? directory,
  }) : _directory = directory ?? getApplicationSupportDirectory;

  static final _accounts = <String, LoomLocalAvatarStore>{};
  static LoomLocalAvatarStore forIdentity(String identityId) => _accounts
      .putIfAbsent(identityId, () => LoomLocalAvatarStore(identityId));

  final String identityId;
  final Future<Directory> Function() _directory;
  Future<void>? _loading;
  Future<void> _writes = Future<void>.value();
  Uint8List? _photo;
  int _colorIndex = 0;
  String? displayName;
  String? revision;
  bool pendingUpload = false;
  bool syncing = false;
  String? syncError;
  int _editGeneration = 0;
  Future<void>? _syncFuture;
  DateTime? _lastAttempt;
  bool get needsSync =>
      _syncFuture == null &&
      (_lastAttempt == null ||
          DateTime.now().difference(_lastAttempt!) >=
              (pendingUpload
                  ? const Duration(seconds: 15)
                  : const Duration(minutes: 2)));

  Uint8List? get photo => _photo;
  int get colorIndex => _colorIndex;

  Future<File> _file() async {
    final root = await _directory();
    final account = base64Url.encode(utf8.encode(identityId));
    return File('${root.path}/profile-avatars/$account.json');
  }

  Future<void> load() => _loading ??= _load();
  Future<void> _load() async {
    try {
      final file = await _file();
      if (!await file.exists() || await file.length() > 2 * 1024 * 1024) {
        return;
      }
      final value = jsonDecode(await file.readAsString());
      if (value is! Map<String, dynamic> || value['version'] != 1) {
        return;
      }
      displayName = value['displayName'] as String?;
      revision = value['revision'] as String?;
      pendingUpload = value['pendingUpload'] == true;
      final color = value['color'];
      if (color is int && color >= 0 && color < 6) {
        _colorIndex = color;
      }
      final encoded = value['png'];
      if (encoded is String) {
        final bytes = base64Decode(encoded);
        if (_validPng(bytes)) {
          _photo = bytes;
        }
      }
      // Old versions only had a local photo/color. Keep it as an outbox edit
      // instead of replacing it with an empty server profile on first sync.
      if (!value.containsKey('pendingUpload') &&
          (_photo != null || _colorIndex != 0)) {
        pendingUpload = true;
      }
      notifyListeners();
    } catch (_) {
      // Missing, corrupt or inaccessible presentation data cannot block login.
    }
  }

  static bool _validPng(Uint8List bytes) =>
      bytes.length >= 8 &&
      bytes.length <= 1500 * 1024 &&
      listEquals(bytes.take(8).toList(), const [
        137,
        80,
        78,
        71,
        13,
        10,
        26,
        10,
      ]);

  Future<void> setPhoto(Uint8List png) {
    if (!_validPng(png)) {
      return Future.error(ArgumentError('Invalid avatar PNG'));
    }
    // Own the bytes: picker/caller buffers must not mutate persisted state.
    final copy = Uint8List.fromList(png);
    return _save(photo: copy, replacePhoto: true);
  }

  Future<void> setDisplayName(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty ||
        trimmed.length > 80 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(trimmed)) {
      return Future.error(ArgumentError('Invalid display name'));
    }
    return _save(name: trimmed);
  }

  Future<void> synchronize({
    required Future<Map<String, Object?>> Function() fetch,
    required Future<Map<String, Object?>> Function(Map<String, Object?>) upload,
    required String fallbackName,
    bool force = false,
  }) => _syncFuture ??= _synchronize(
    fetch,
    upload,
    fallbackName,
    force,
  ).whenComplete(() => _syncFuture = null);

  Future<void> _synchronize(
    Future<Map<String, Object?>> Function() fetch,
    Future<Map<String, Object?>> Function(Map<String, Object?>) upload,
    String fallbackName,
    bool force,
  ) async {
    await load();
    await _writes;
    if (!force &&
        _lastAttempt != null &&
        DateTime.now().difference(_lastAttempt!) <
            (pendingUpload
                ? const Duration(seconds: 15)
                : const Duration(minutes: 2))) {
      return;
    }
    _lastAttempt = DateTime.now();
    final generation = _editGeneration;
    syncing = true;
    notifyListeners();
    try {
      var uploadPhoto = _photo;
      if (pendingUpload && uploadPhoto != null) {
        // Before profile sync existed the picker produced 512px images. Resize
        // those only for upload; a failed request retains the original locally.
        final header = ByteData.sublistView(uploadPhoto);
        if (uploadPhoto.length < 24 ||
            header.getUint32(16) > 256 ||
            header.getUint32(20) > 256 ||
            uploadPhoto.length > 337500) {
          uploadPhoto = await normalizeAvatarPhoto(uploadPhoto);
        }
      }
      if (generation != _editGeneration) {
        return;
      }
      final remote = pendingUpload
          ? await upload({
              'displayName': displayName ?? fallbackName,
              'avatar': {
                'png': uploadPhoto == null ? null : base64Encode(uploadPhoto),
                'color': _colorIndex,
              },
            })
          : await fetch();
      // An in-flight fetch/upload must never discard a newer picker selection.
      if (generation != _editGeneration) {
        return;
      }
      final avatar = remote['avatar'];
      if (avatar is! Map) {
        throw const FormatException('Invalid public profile');
      }
      final png = avatar['png'];
      final bytes = png is String ? base64Decode(png) : null;
      if (bytes != null && !_validPng(bytes)) {
        throw const FormatException('Invalid public avatar');
      }
      if (generation != _editGeneration) {
        return;
      }
      await _save(
        photo: bytes,
        replacePhoto: true,
        color: avatar['color'] as int?,
        name: remote['displayName'] as String?,
        remoteRevision: remote['revision'] as String?,
        remote: true,
        expectedGeneration: generation,
      );
      syncError = null;
    } catch (_) {
      syncError = 'profile_sync_failed';
    } finally {
      syncing = false;
      notifyListeners();
    }
  }

  // Verified peer profiles use the same presentation cache, without an upload.
  Future<void> cachePeer({
    required String name,
    required String? png,
    required int color,
  }) async {
    await load();
    await _writes;
    if (pendingUpload) {
      return;
    }
    final bytes = png == null ? null : base64Decode(png);
    if (name == displayName &&
        color == _colorIndex &&
        listEquals(bytes, _photo)) {
      return;
    }
    await _save(
      photo: bytes,
      replacePhoto: true,
      name: name,
      color: color,
      remote: true,
      expectedGeneration: _editGeneration,
    );
  }

  Future<void> removePhoto() => _save(replacePhoto: true);
  Future<void> setColor(int index) {
    if (index < 0 || index >= 6) {
      return Future.error(RangeError.range(index, 0, 5));
    }
    return _save(color: index);
  }

  Future<void> _save({
    Uint8List? photo,
    bool replacePhoto = false,
    int? color,
    String? name,
    String? remoteRevision,
    bool remote = false,
    int? expectedGeneration,
  }) {
    if (!remote) {
      _editGeneration++;
    }
    final operation = _writes.then((_) async {
      await load();
      if (expectedGeneration != null && _editGeneration != expectedGeneration) {
        return;
      }
      final nextPhoto = replacePhoto ? photo : _photo;
      final nextColor = color ?? _colorIndex;
      if (nextColor < 0 ||
          nextColor >= 6 ||
          (nextPhoto != null && !_validPng(nextPhoto))) {
        throw const FormatException('Invalid avatar');
      }
      final nextName = name ?? displayName;
      final nextRevision = remote ? remoteRevision : revision;
      final nextPending = !remote;
      final file = await _file();
      await file.parent.create(recursive: true);
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(
        jsonEncode({
          'version': 1,
          'color': nextColor,
          'displayName': nextName,
          'revision': nextRevision,
          'pendingUpload': nextPending,
          if (nextPhoto != null) 'png': base64Encode(nextPhoto),
        }),
        flush: true,
      );
      await temporary.rename(file.path);
      displayName = nextName;
      revision = nextRevision;
      pendingUpload = nextPending;
      _photo = nextPhoto;
      _colorIndex = nextColor;
      notifyListeners();
    });
    // A failed write is reported to the caller, but must not poison later saves.
    _writes = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return operation;
  }
}
