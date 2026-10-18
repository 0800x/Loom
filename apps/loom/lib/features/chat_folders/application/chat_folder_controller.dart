import 'dart:convert';
import 'dart:io';

import 'package:loom_models/loom_models.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

const String loomAllChatsFolderId = 'all';
const String loomUnreadFolderId = 'unread';
const String loomPersonalFolderId = 'personal';
const String loomGroupsFolderId = 'groups';
const String loomPinnedFolderId = 'pinned';
const String loomMutedFolderId = 'muted';
const int _chatFolderConfigVersion = 2;

class LoomChatFolderDefinition {
  const LoomChatFolderDefinition({
    required this.id,
    required this.name,
    this.includeDirect = false,
    this.includeGroups = false,
    this.includeSelf = false,
    this.unreadOnly = false,
    this.pinnedOnly = false,
    this.mutedOnly = false,
  });

  final String id;
  final String name;
  final bool includeDirect;
  final bool includeGroups;
  final bool includeSelf;
  final bool unreadOnly;
  final bool pinnedOnly;
  final bool mutedOnly;

  bool get locked => id == loomAllChatsFolderId;
  bool get preset => const <String>{
    loomAllChatsFolderId,
    loomUnreadFolderId,
    loomPersonalFolderId,
    loomGroupsFolderId,
    loomPinnedFolderId,
    loomMutedFolderId,
  }.contains(id);

  bool matches(LoomConversation conversation) {
    if (locked) return true;

    final hasKindRule = includeDirect || includeGroups || includeSelf;
    if (hasKindRule) {
      final kindMatches = switch (conversation.kind) {
        LoomConversationKind.direct => includeDirect,
        LoomConversationKind.group => includeGroups,
        LoomConversationKind.self => includeSelf,
      };
      if (!kindMatches) return false;
    }
    if (unreadOnly && conversation.unreadCount <= 0) return false;
    if (pinnedOnly && !conversation.isPinned) return false;
    if (mutedOnly && !conversation.isMuted) return false;
    return true;
  }

  LoomChatFolderDefinition copyWith({
    String? name,
    bool? includeDirect,
    bool? includeGroups,
    bool? includeSelf,
    bool? unreadOnly,
    bool? pinnedOnly,
    bool? mutedOnly,
  }) => LoomChatFolderDefinition(
    id: id,
    name: name ?? this.name,
    includeDirect: includeDirect ?? this.includeDirect,
    includeGroups: includeGroups ?? this.includeGroups,
    includeSelf: includeSelf ?? this.includeSelf,
    unreadOnly: unreadOnly ?? this.unreadOnly,
    pinnedOnly: pinnedOnly ?? this.pinnedOnly,
    mutedOnly: mutedOnly ?? this.mutedOnly,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'includeDirect': includeDirect,
    'includeGroups': includeGroups,
    'includeSelf': includeSelf,
    'unreadOnly': unreadOnly,
    'pinnedOnly': pinnedOnly,
    'mutedOnly': mutedOnly,
  };

  factory LoomChatFolderDefinition.fromJson(Map<String, Object?> json) {
    final id = json['id'];
    final name = json['name'];
    if (id is! String ||
        id.trim().isEmpty ||
        id.length > 80 ||
        name is! String ||
        name.trim().isEmpty ||
        name.trim().length > 32) {
      throw const FormatException('Invalid chat folder identity');
    }
    bool flag(String key) {
      final value = json[key];
      if (value == null) return false;
      if (value is! bool) throw FormatException('Invalid chat folder $key');
      return value;
    }

    return LoomChatFolderDefinition(
      id: id.trim(),
      name: name.trim(),
      includeDirect: flag('includeDirect'),
      includeGroups: flag('includeGroups'),
      includeSelf: flag('includeSelf'),
      unreadOnly: flag('unreadOnly'),
      pinnedOnly: flag('pinnedOnly'),
      mutedOnly: flag('mutedOnly'),
    );
  }
}

class LoomChatFolderController extends ChangeNotifier {
  LoomChatFolderController({
    required this._identityIdProvider,
    Future<Directory> Function()? supportDirectoryProvider,
  }) : _supportDirectoryProvider =
           supportDirectoryProvider ?? getApplicationSupportDirectory;

  final String? Function() _identityIdProvider;
  final Future<Directory> Function() _supportDirectoryProvider;

  List<LoomChatFolderDefinition> _folders = _defaultFolders();
  String? _boundIdentityId;
  bool _opening = false;
  int _customCounter = 0;
  String? errorMessage;

  List<LoomChatFolderDefinition> get folders =>
      List<LoomChatFolderDefinition>.unmodifiable(_folders);
  bool get opening => _opening;

  List<LoomChatFolderDefinition> get recommendations {
    final active = _folders.map((folder) => folder.id).toSet();
    return _recommendationFolders()
        .where((folder) => !active.contains(folder.id))
        .toList(growable: false);
  }

  Future<void> open() async {
    if (_opening) return;
    final identity = _identityIdProvider()?.trim();
    if (identity == null || identity.isEmpty) {
      if (_boundIdentityId != null) {
        _boundIdentityId = null;
        _folders = _defaultFolders();
        errorMessage = null;
        notifyListeners();
      }
      return;
    }
    if (_boundIdentityId == identity) return;

    _opening = true;
    notifyListeners();
    try {
      final file = await _fileFor(identity);
      if (!await file.exists()) {
        _folders = _defaultFolders();
        _boundIdentityId = identity;
        errorMessage = null;
        await _persist();
        return;
      }
      final bytes = await file.readAsBytes();
      if (bytes.length > 256 * 1024) {
        throw const FormatException('Chat folder settings are too large');
      }
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, Object?>) {
        throw const FormatException('Unsupported chat folder settings');
      }
      final version = decoded['version'];
      if (version != 1 && version != _chatFolderConfigVersion) {
        throw const FormatException('Unsupported chat folder settings');
      }
      final rawFolders = decoded['folders'];
      if (rawFolders is! List || rawFolders.length > 20) {
        throw const FormatException('Invalid chat folder list');
      }
      final parsed = <LoomChatFolderDefinition>[];
      final ids = <String>{};
      for (final item in rawFolders) {
        if (item is! Map) throw const FormatException('Invalid chat folder');
        final folder = LoomChatFolderDefinition.fromJson(
          item.cast<String, Object?>(),
        );
        if (!ids.add(folder.id)) {
          throw const FormatException('Duplicate chat folder');
        }
        parsed.add(folder);
      }
      final normalized = _normalize(parsed);
      _folders = version == 1 && _isLegacyDefaultLayout(normalized)
          ? _defaultFolders()
          : normalized;
      _boundIdentityId = identity;
      errorMessage = null;
      if (version != _chatFolderConfigVersion) {
        await _persist();
      }
    } catch (_) {
      _folders = _defaultFolders();
      _boundIdentityId = identity;
      errorMessage =
          'Could not read saved chat folders. Folder setup was reset.';
      try {
        await _persist();
      } catch (_) {}
    } finally {
      _opening = false;
      notifyListeners();
      final currentIdentity = _identityIdProvider()?.trim();
      final needsRefresh = currentIdentity == null || currentIdentity.isEmpty
          ? _boundIdentityId != null
          : currentIdentity != _boundIdentityId;
      if (needsRefresh) await open();
    }
  }

  List<LoomConversation> apply(
    Iterable<LoomConversation> conversations,
    LoomChatFolderDefinition folder,
  ) => conversations.where(folder.matches).toList(growable: false);

  Future<void> addPreset(String id) async {
    if (_folders.length >= 10 || _folders.any((folder) => folder.id == id)) {
      return;
    }
    LoomChatFolderDefinition? candidate;
    for (final folder in _recommendationFolders()) {
      if (folder.id == id) {
        candidate = folder;
        break;
      }
    }
    if (candidate == null) return;
    _folders = <LoomChatFolderDefinition>[..._folders, candidate];
    notifyListeners();
    await _persistSafely();
  }

  Future<void> createCustom({
    required String name,
    required bool includeDirect,
    required bool includeGroups,
    required bool includeSelf,
    required bool unreadOnly,
    required bool pinnedOnly,
    required bool mutedOnly,
  }) async {
    final cleanName = name.trim();
    if (cleanName.isEmpty || cleanName.length > 32 || _folders.length >= 10) {
      return;
    }
    final now = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final id = 'custom-$now-${_customCounter++}';
    _folders = <LoomChatFolderDefinition>[
      ..._folders,
      LoomChatFolderDefinition(
        id: id,
        name: cleanName,
        includeDirect: includeDirect,
        includeGroups: includeGroups,
        includeSelf: includeSelf,
        unreadOnly: unreadOnly,
        pinnedOnly: pinnedOnly,
        mutedOnly: mutedOnly,
      ),
    ];
    notifyListeners();
    await _persistSafely();
  }

  Future<void> updateCustom(
    String id, {
    required String name,
    required bool includeDirect,
    required bool includeGroups,
    required bool includeSelf,
    required bool unreadOnly,
    required bool pinnedOnly,
    required bool mutedOnly,
  }) async {
    final cleanName = name.trim();
    final index = _folders.indexWhere((folder) => folder.id == id);
    if (index <= 0 || cleanName.isEmpty || cleanName.length > 32) return;
    final existing = _folders[index];
    if (existing.preset) return;
    final next = existing.copyWith(
      name: cleanName,
      includeDirect: includeDirect,
      includeGroups: includeGroups,
      includeSelf: includeSelf,
      unreadOnly: unreadOnly,
      pinnedOnly: pinnedOnly,
      mutedOnly: mutedOnly,
    );
    _folders = <LoomChatFolderDefinition>[
      ..._folders.take(index),
      next,
      ..._folders.skip(index + 1),
    ];
    notifyListeners();
    await _persistSafely();
  }

  Future<void> remove(String id) async {
    if (id == loomAllChatsFolderId) return;
    final next = _folders.where((folder) => folder.id != id).toList();
    if (next.length == _folders.length) return;
    _folders = next;
    notifyListeners();
    await _persistSafely();
  }

  Future<void> reorder(int oldIndex, int newIndex) async {
    if (oldIndex <= 0 || oldIndex >= _folders.length) return;
    if (newIndex <= 0) newIndex = 1;
    if (newIndex > _folders.length) newIndex = _folders.length;
    final next = List<LoomChatFolderDefinition>.from(_folders);
    final item = next.removeAt(oldIndex);
    if (newIndex > oldIndex) newIndex -= 1;
    next.insert(newIndex.clamp(1, next.length).toInt(), item);
    _folders = next;
    notifyListeners();
    await _persistSafely();
  }

  Future<void> restoreDefaults() async {
    _folders = _defaultFolders();
    errorMessage = null;
    notifyListeners();
    await _persistSafely();
  }

  Future<File> _fileFor(String identity) async {
    final directory = await _supportDirectoryProvider();
    await directory.create(recursive: true);
    final safeIdentity = identity.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    return File('${directory.path}/loom-chat-folders-$safeIdentity.json');
  }

  Future<void> _persistSafely() async {
    try {
      await _persist();
      errorMessage = null;
    } catch (_) {
      errorMessage = 'Could not save chat folder settings.';
      notifyListeners();
    }
  }

  Future<void> _persist() async {
    final identity = (_boundIdentityId ?? _identityIdProvider())?.trim();
    if (identity == null || identity.isEmpty) return;
    _boundIdentityId = identity;
    final file = await _fileFor(identity);
    final temp = File('${file.path}.tmp');
    final payload = utf8.encode(
      jsonEncode(<String, Object?>{
        'version': _chatFolderConfigVersion,
        'folders': _folders
            .map((folder) => folder.toJson())
            .toList(growable: false),
      }),
    );
    await temp.writeAsBytes(payload, flush: true);
    if (await file.exists()) await file.delete();
    await temp.rename(file.path);
  }

  static List<LoomChatFolderDefinition> _normalize(
    List<LoomChatFolderDefinition> input,
  ) {
    final result = <LoomChatFolderDefinition>[
      const LoomChatFolderDefinition(
        id: loomAllChatsFolderId,
        name: 'All Chats',
      ),
    ];
    for (final folder in input) {
      if (folder.id == loomAllChatsFolderId || result.length >= 10) continue;
      result.add(folder);
    }
    return result;
  }

  static bool _isLegacyDefaultLayout(List<LoomChatFolderDefinition> folders) {
    const legacyIds = <String>[
      loomAllChatsFolderId,
      loomUnreadFolderId,
      loomPersonalFolderId,
      loomGroupsFolderId,
      loomPinnedFolderId,
    ];
    if (folders.length != legacyIds.length) return false;
    for (var index = 0; index < legacyIds.length; index++) {
      if (folders[index].id != legacyIds[index]) return false;
    }
    return true;
  }

  static List<LoomChatFolderDefinition> _defaultFolders() => const [
    LoomChatFolderDefinition(id: loomAllChatsFolderId, name: 'All Chats'),
  ];

  static List<LoomChatFolderDefinition> _recommendationFolders() => const [
    LoomChatFolderDefinition(
      id: loomUnreadFolderId,
      name: 'Unread',
      unreadOnly: true,
    ),
    LoomChatFolderDefinition(
      id: loomPersonalFolderId,
      name: 'Personal',
      includeDirect: true,
      includeSelf: true,
    ),
    LoomChatFolderDefinition(
      id: loomGroupsFolderId,
      name: 'Groups',
      includeGroups: true,
    ),
    LoomChatFolderDefinition(
      id: loomPinnedFolderId,
      name: 'Pinned',
      pinnedOnly: true,
    ),
    LoomChatFolderDefinition(
      id: loomMutedFolderId,
      name: 'Muted',
      mutedOnly: true,
    ),
  ];
}

class LoomChatFoldersScope extends InheritedNotifier<LoomChatFolderController> {
  const LoomChatFoldersScope({
    required LoomChatFolderController controller,
    required super.child,
    super.key,
  }) : super(notifier: controller);

  static LoomChatFolderController of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<LoomChatFoldersScope>();
    assert(scope != null, 'LoomChatFoldersScope is missing');
    return scope!.notifier!;
  }

  static LoomChatFolderController? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<LoomChatFoldersScope>()
      ?.notifier;
}
