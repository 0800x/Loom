part of 'messenger_shell.dart';

/// Motion duration honoring the reduced-motion accessibility preference.
Duration _motionDuration(BuildContext context, int milliseconds) =>
    LoomAccessibility.fromContext(context).reduceMotion
    ? Duration.zero
    : Duration(milliseconds: milliseconds);

class _ConversationPane extends StatefulWidget {
  const _ConversationPane({
    required this.preview,
    required this.messaging,
    required this.conversation,
    required this.drafts,
    this.onBack,
    this.onToggleDetails,
    super.key,
  });

  final bool preview;
  final LoomMessagingSessionController? messaging;
  final models.LoomConversation? conversation;
  final _ConversationDrafts drafts;
  final VoidCallback? onBack;
  final VoidCallback? onToggleDetails;

  @override
  State<_ConversationPane> createState() => _ConversationPaneState();
}

class _ConversationPaneState extends State<_ConversationPane>
    with WidgetsBindingObserver {
  final composer = TextEditingController();
  final composerFocus = FocusNode();
  late final ScrollController messageScroll;
  bool sending = false;
  bool _uploading = false;
  bool _mediaPreviewOpen = false;
  bool searching = false;
  String query = '';
  bool calling = false;
  String? _readSnapshot;
  bool _readScheduled = false;
  final _messageKeys = <String, GlobalKey>{};
  String? _highlighted;
  Timer? _highlightTimer;
  final _knownMessages = <String>{};
  final _enteringMessages = <String>{};
  DateTime? _latestMessageAt;
  int _scrollEpoch = 0;
  List<LoomVisibleMessage>? _observedMessages;
  final _messagesByClientId = <String, LoomVisibleMessage>{};
  final _messagesById = <String, LoomVisibleMessage>{};
  final _messageIndexes = <String, int>{};

  String? get _draftId => widget.preview ? 'preview' : widget.conversation?.id;

  @override
  void initState() {
    super.initState();
    messageScroll = ScrollController(
      initialScrollOffset: widget.drafts.scrollOffsets[_draftId] ?? 0,
    );
    WidgetsBinding.instance.addObserver(this);
    messageScroll.addListener(_scheduleRead);
    messageScroll.addListener(_saveScroll);
    composer.value = widget.drafts[_draftId] ?? TextEditingValue.empty;
    composer.addListener(_saveDraft);
    _observeMessages(initial: true);
  }

  void _observeMessages({bool initial = false}) {
    final id = widget.conversation?.id;
    final all = id == null
        ? const <LoomVisibleMessage>[]
        : widget.messaging?.visibleMessagesFor(id) ??
              const <LoomVisibleMessage>[];
    if (!initial && identical(all, _observedMessages)) return;
    _observedMessages = all;
    _messagesByClientId.clear();
    _messagesById.clear();
    for (final message in all) {
      _messagesByClientId[message.record.clientId] = message;
      _messagesById[message.record.id] = message;
    }
    final ids = _messagesByClientId.keys.toSet();
    final inserted = ids.difference(_knownMessages);
    final nearBottom = !messageScroll.hasClients || messageScroll.offset <= 80;
    final latest = _latestMessageAt;
    final newTail = all.any(
      (m) =>
          inserted.contains(m.record.clientId) &&
          (latest == null || !m.record.createdAt.isBefore(latest)),
    );
    if (!initial && newTail && nearBottom) {
      _enteringMessages.addAll(
        all
            .where(
              (m) =>
                  inserted.contains(m.record.clientId) &&
                  (latest == null || !m.record.createdAt.isBefore(latest)),
            )
            .map((m) => m.record.clientId),
      );
    }
    if (!initial && inserted.isNotEmpty && messageScroll.hasClients) {
      final epoch = ++_scrollEpoch;
      GlobalKey? anchor;
      double? anchorY;
      if (!nearBottom) {
        for (final key in _messageKeys.values) {
          final box = key.currentContext?.findRenderObject();
          if (box is RenderBox && box.hasSize) {
            final y = box.localToGlobal(Offset.zero).dy;
            if (y >= 90 && y <= MediaQuery.sizeOf(context).height - 140) {
              anchor = key;
              anchorY = y;
              break;
            }
          }
        }
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || epoch != _scrollEpoch || !messageScroll.hasClients) {
          return;
        }
        if (nearBottom && newTail) {
          final duration = LoomAccessibility.fromContext(context).reduceMotion
              ? Duration.zero
              : const Duration(milliseconds: 180);
          if (duration == Duration.zero) {
            messageScroll.jumpTo(0);
          } else {
            unawaited(
              messageScroll.animateTo(
                0,
                duration: duration,
                curve: Curves.easeOut,
              ),
            );
          }
        } else if (anchor != null && anchorY != null) {
          final box = anchor.currentContext?.findRenderObject();
          if (box is RenderBox && box.hasSize) {
            final delta = anchorY - box.localToGlobal(Offset.zero).dy;
            if (delta.abs() > .5) {
              messageScroll.jumpTo(
                (messageScroll.offset + delta)
                    .clamp(0.0, messageScroll.position.maxScrollExtent)
                    .toDouble(),
              );
            }
          }
        }
      });
    }
    _latestMessageAt = all.isEmpty
        ? null
        : all
              .map((m) => m.record.createdAt)
              .reduce((a, b) => a.isAfter(b) ? a : b);
    _messageKeys.removeWhere((key, _) => !ids.contains(key));
    _enteringMessages.retainAll(ids);
    _knownMessages
      ..clear()
      ..addAll(ids);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _scheduleRead();
    }
  }

  void _scheduleRead() {
    if (_readScheduled || !mounted) return;
    _readScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _readScheduled = false;
      if (!mounted ||
          !TickerMode.valuesOf(context).enabled ||
          (WidgetsBinding.instance.lifecycleState != null &&
              WidgetsBinding.instance.lifecycleState !=
                  AppLifecycleState.resumed) ||
          (messageScroll.hasClients && messageScroll.offset > 80)) {
        return;
      }
      final id = widget.conversation?.id;
      final messaging = widget.messaging;
      if (id == null || messaging == null) {
        return;
      }
      messaging.watchConversation(id, owner: this);
      final fingerprint =
          '$id:${messaging.visibleMessagesFor(id).where((m) => m.readable).map((m) => m.record.clientId).join(',')}';
      if (_readSnapshot == fingerprint) {
        return;
      }
      _readSnapshot = fingerprint;
      unawaited(messaging.markConversationRead(id));
    });
  }

  void _saveDraft() {
    final id = _draftId;
    if (id == null) {
      return;
    }
    if (composer.text.isEmpty) {
      widget.drafts.remove(id);
    } else {
      widget.drafts[id] = composer.value;
    }
  }

  void _saveScroll() {
    final id = _draftId;
    if (id != null && messageScroll.hasClients) {
      widget.drafts.scrollOffsets[id] = messageScroll.offset;
    }
  }

  @override
  void didUpdateWidget(covariant _ConversationPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.conversation?.id != widget.conversation?.id) {
      // Every edit is already saved under its own conversation ID.
      composer.removeListener(_saveDraft);
      composer.value = widget.drafts[_draftId] ?? TextEditingValue.empty;
      composer.addListener(_saveDraft);
      searching = false;
      query = '';
      _enteringMessages.clear();
      ++_scrollEpoch;
      _observeMessages(initial: true);
      if (messageScroll.hasClients) {
        messageScroll.jumpTo(widget.drafts.scrollOffsets[_draftId] ?? 0);
      }
    } else {
      _observeMessages();
    }
  }

  @override
  void dispose() {
    ++_scrollEpoch;
    _highlightTimer?.cancel();
    widget.messaging?.releaseConversationWatcher(this);
    WidgetsBinding.instance.removeObserver(this);
    messageScroll.removeListener(_scheduleRead);
    composer.removeListener(_saveDraft);
    composer.dispose();
    composerFocus.dispose();
    messageScroll.dispose();
    super.dispose();
  }

  Future<void> _jumpToReply(String clientId) async {
    final conversationId = widget.conversation?.id;
    final all = conversationId == null
        ? const <LoomVisibleMessage>[]
        : widget.messaging?.visibleMessagesFor(conversationId) ??
              const <LoomVisibleMessage>[];
    final index = all.indexWhere((m) => m.record.clientId == clientId);
    if (index < 0 || !messageScroll.hasClients) {
      _showComingSoon(
        context,
        tr(
          context,
          'Original message is not loaded',
          'پیام اصلی بارگذاری نشده است',
        ),
      );
      return;
    }
    // Prefer the actual rendered position. Approximate only to bring a lazy
    // item into the viewport; then use ensureVisible on its real geometry.
    if (_messageKeys[clientId]?.currentContext == null) {
      await messageScroll.animateTo(
        (messageScroll.position.maxScrollExtent * index / all.length).clamp(
          0.0,
          messageScroll.position.maxScrollExtent,
        ),
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
      await WidgetsBinding.instance.endOfFrame;
    }
    if (!mounted || widget.conversation?.id != conversationId) return;
    final target = _messageKeys[clientId]?.currentContext;
    if (target == null || !target.mounted) return;
    await Scrollable.ensureVisible(
      target,
      alignment: .5,
      duration: const Duration(milliseconds: 180),
    );
    if (!mounted || widget.conversation?.id != conversationId) return;
    setState(() => _highlighted = clientId);
    _highlightTimer?.cancel();
    _highlightTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _highlighted = null);
    });
  }

  Future<void> _send() async {
    final messaging = widget.messaging;
    final conversation = widget.conversation;
    final submitted = composer.value;
    final reply = widget.drafts.replies[conversation?.id];
    if (messaging == null ||
        conversation == null ||
        submitted.text.trim().isEmpty ||
        sending) {
      return;
    }
    setState(() => sending = true);
    try {
      final queued = await messaging.sendText(
        conversation.id,
        submitted.text,
        replyToMessageId: reply?.record.id.startsWith('local:') == false
            ? reply!.record.id
            : null,
        reply: reply,
      );
      if (queued && widget.drafts.replies[conversation.id] == reply) {
        widget.drafts.replies.remove(conversation.id);
      }
      // A slow key lookup must never erase text typed since Send, or a draft
      // belonging to a different conversation opened while queueing.
      if (queued && widget.drafts[conversation.id]?.text == submitted.text) {
        widget.drafts.remove(conversation.id);
      }
      if (!mounted) {
        return;
      }
      if (queued && widget.conversation?.id == conversation.id) {
        if (composer.text == submitted.text) {
          composer.clear();
        }
        if (messageScroll.hasClients) {
          final reduceMotion = LoomAccessibility.fromContext(
            context,
          ).reduceMotion;
          if (reduceMotion) {
            messageScroll.jumpTo(0);
          } else {
            unawaited(
              messageScroll.animateTo(
                0,
                duration: LoomMotion.component,
                curve: LoomMotion.standard,
              ),
            );
          }
        }
        composerFocus.requestFocus();
      } else if (!queued) {
        _showComingSoon(
          context,
          tr(
            context,
            'Could not queue the message. Your draft is kept. Check the details above.',
            'پیام در صف قرار نگرفت. پیش‌نویس حفظ شد؛ جزئیات خطا را در بالای گفتگو بررسی کنید.',
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => sending = false);
      }
    }
  }

  Future<void> _insertKeyboardMedia(KeyboardInsertedContent content) async {
    final target = widget.conversation;
    final session = widget.messaging;
    if (target == null ||
        session == null ||
        _uploading ||
        LoomAppLock.instance.locked) {
      return;
    }
    var data = content.data;
    if (data == null &&
        Platform.isAndroid &&
        content.uri.startsWith('content://')) {
      try {
        data = await const MethodChannel(
          'loom/keyboard_media',
        ).invokeMethod<Uint8List>('readKeyboardImage', {'uri': content.uri});
      } catch (_) {}
      if (!mounted ||
          widget.conversation?.id != target.id ||
          LoomAppLock.instance.locked) {
        return;
      }
    }
    if (data == null ||
        data.isEmpty ||
        data.length > 32 * 1024 * 1024 ||
        !const [
          'image/gif',
          'image/png',
          'image/jpeg',
          'image/webp',
        ].contains(content.mimeType)) {
      _showComingSoon(
        context,
        tr(
          context,
          'Keyboard image unavailable. Use Attach → GIF or Gallery.',
          'تصویر کیبورد در دسترس نیست؛ از پیوست، GIF یا گالری استفاده کنید.',
        ),
      );
      return;
    }
    File? file;
    bool staged = false;
    try {
      final temp = await getTemporaryDirectory();
      final root = await Directory(
        '${temp.path}/loom_media_keyboard',
      ).create(recursive: true);
      final folder = await root.createTemp('insert_');
      final ext = content.mimeType == 'image/gif'
          ? 'gif'
          : content.mimeType == 'image/webp'
          ? 'webp'
          : content.mimeType == 'image/png'
          ? 'png'
          : 'jpg';
      file = File('${folder.path}/keyboard.$ext');
      await file.writeAsBytes(data, flush: true);
      await LoomMediaPreparation.dimensions(file, 'image');
      final sticker = await LoomMediaPreparation.keyboardSticker(
        file,
        content.mimeType,
      );
      if (!mounted ||
          widget.conversation?.id != target.id ||
          LoomAppLock.instance.locked) {
        return;
      }
      session.stagePickedMedia(
        target.id,
        file,
        false,
        kind: 'image',
        sticker: sticker,
        owned: true,
      );
      staged = true;
      await _previewPendingMedia();
    } catch (_) {
      if (mounted) {
        _showComingSoon(
          context,
          tr(
            context,
            'Image could not be inserted.',
            'تصویر قابل افزودن نیست.',
          ),
        );
      }
    } finally {
      if (!staged && file != null) {
        try {
          await file.parent.delete(recursive: true);
        } catch (_) {}
      }
    }
  }

  Future<void> _sendAttachment(String choice) async {
    final messaging = widget.messaging;
    final conversation = widget.conversation;
    if (messaging == null || conversation == null || sending || _uploading) {
      return;
    }
    try {
      if (choice == 'location' || choice == 'live') {
        final position = await messaging.currentPosition();
        if (!mounted ||
            widget.conversation?.id != conversation.id ||
            LoomAppLock.instance.locked) {
          return;
        }
        final duration = await _chooseLocation(
          context,
          LatLng(position.latitude, position.longitude),
          live: choice == 'live',
        );
        if (!mounted ||
            duration == null ||
            widget.conversation?.id != conversation.id ||
            LoomAppLock.instance.locked) {
          return;
        }
        final ok = choice == 'live'
            ? await messaging.startLiveLocation(
                conversation.id,
                duration,
                initialPosition: position,
              )
            : await messaging.sendLocation(
                conversation.id,
                position.latitude,
                position.longitude,
              );
        if (!ok && mounted) {
          _showComingSoon(
            context,
            tr(
              context,
              'Location was not sent. Please retry.',
              'موقعیت ارسال نشد؛ دوباره تلاش کنید.',
            ),
          );
        }
        return;
      }
      if (choice == 'file') {
        final selected = await openFile();
        if (selected == null ||
            !mounted ||
            LoomAppLock.instance.locked ||
            widget.conversation?.id != conversation.id) {
          return;
        }
        final submitted = composer.value;
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(tr(context, 'Send file', 'ارسال فایل')),
            content: Text(selected.name),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(tr(context, 'Cancel', 'لغو')),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(tr(context, 'Send', 'ارسال')),
              ),
            ],
          ),
        );
        if (confirmed != true ||
            !mounted ||
            widget.conversation?.id != conversation.id ||
            LoomAppLock.instance.locked) {
          return;
        }
        setState(() => sending = true);
        try {
          final ok = await messaging.sendMedia(
            conversation.id,
            File(selected.path),
            'file',
            caption: submitted.text,
            reply: widget.drafts.replies[conversation.id],
          );
          if (ok &&
              mounted &&
              widget.conversation?.id == conversation.id &&
              composer.text == submitted.text) {
            composer.clear();
          }
          if (!ok && mounted) {
            _showComingSoon(
              context,
              tr(
                context,
                'File was not sent. Your draft is kept.',
                'فایل ارسال نشد؛ پیش‌نویس حفظ شد.',
              ),
            );
          }
        } finally {
          if (mounted) setState(() => sending = false);
        }
        return;
      }
      if (choice == 'gif') {
        final selected = await openFile(
          acceptedTypeGroups: const [
            XTypeGroup(
              label: 'GIF',
              extensions: ['gif'],
              mimeTypes: ['image/gif'],
            ),
          ],
        );
        if (selected == null ||
            !mounted ||
            LoomAppLock.instance.locked ||
            widget.conversation?.id != conversation.id) {
          return;
        }
        messaging.stagePickedMedia(
          conversation.id,
          File(selected.path),
          false,
          kind: 'image',
        );
        await _previewPendingMedia();
        return;
      }
      if (choice == 'music') {
        final selected = await openFile(
          acceptedTypeGroups: const [
            XTypeGroup(
              label: 'Audio',
              extensions: [
                'mp3',
                'm4a',
                'aac',
                'ogg',
                'opus',
                'flac',
                'wav',
                'aiff',
                'wma',
              ],
              mimeTypes: ['audio/*'],
            ),
          ],
        );
        if (selected == null ||
            !mounted ||
            LoomAppLock.instance.locked ||
            widget.conversation?.id != conversation.id) {
          return;
        }
        messaging.stagePickedMedia(
          conversation.id,
          File(selected.path),
          false,
          kind: 'audio',
          music: true,
        );
        await _previewPendingMedia();
        return;
      }
      final video =
          choice == 'video' ||
          choice == 'camera_video' ||
          choice == 'video_note';
      if (choice.startsWith('camera') || choice == 'video_note') {
        final capture = await Navigator.push<LoomCameraCapture>(
          context,
          MaterialPageRoute(
            builder: (_) => LoomCameraScreen(
              video: video,
              videoNote: choice == 'video_note',
            ),
          ),
        );
        if (capture == null) return;
        if (!mounted ||
            LoomAppLock.instance.locked ||
            widget.conversation?.id != conversation.id) {
          try {
            await capture.file.delete();
          } catch (_) {}
          return;
        }
        messaging.stagePickedMedia(
          conversation.id,
          capture.file,
          capture.kind != 'image',
          kind: capture.kind,
          owned: true,
        );
        await _previewPendingMedia();
        return;
      }
      const source = ImageSource.gallery;
      final picker = ImagePicker();
      final picked = video
          ? await picker.pickVideo(
              source: source,
              maxDuration: const Duration(minutes: 1),
            )
          : await picker.pickImage(
              source: source,
              maxWidth: 2560,
              maxHeight: 2560,
              imageQuality: 88,
            );
      if (picked == null) {
        return;
      }
      // The OS picker can pause Android and App Lock removes this route. Keep
      // only the selected file reference, never history or a quote, across that
      // return; the new route offers an explicit preview after unlocking.
      messaging.stagePickedMedia(
        conversation.id,
        File(picked.path),
        video,
        kind: choice == 'video_note' ? 'video_note' : null,
        owned: source == ImageSource.camera,
      );
      if (mounted &&
          widget.conversation?.id == conversation.id &&
          !LoomAppLock.instance.locked) {
        await _previewPendingMedia();
      }
    } catch (_) {
      if (mounted) {
        _showComingSoon(
          context,
          tr(
            context,
            'Could not access the camera, media or location. Check system permissions and retry.',
            'دسترسی به دوربین، مدیا یا موقعیت ممکن نشد؛ مجوزهای سیستم را بررسی کنید.',
          ),
        );
      }
    }
  }

  Future<void> _previewPendingMedia() async {
    final messaging = widget.messaging;
    final conversation = widget.conversation;
    final pending = messaging?.pendingMedia;
    if (messaging == null ||
        conversation == null ||
        pending == null ||
        pending.conversationId != conversation.id ||
        sending ||
        _uploading ||
        _mediaPreviewOpen ||
        LoomAppLock.instance.locked) {
      return;
    }
    _mediaPreviewOpen = true;
    var file = pending.file;
    final video = pending.video;
    final voice = pending.kind == 'audio';
    LoomPreparedMedia? prepared;
    final reply = widget.drafts.replies[conversation.id];
    try {
      final sourceLength = await file.length();
      if (sourceLength <= 0 || sourceLength > 256 * 1024 * 1024) {
        throw const FormatException('Media source exceeds processing limit');
      }
      if (!mounted ||
          messaging.pendingMedia != pending ||
          LoomAppLock.instance.locked ||
          widget.conversation?.id != conversation.id) {
        return;
      }
      if (!mounted) {
        return;
      }
      final caption = TextEditingController(
        text: pending.sticker ? '' : composer.text,
      );
      String? confirmed;
      try {
        if (pending.sticker) {
          confirmed = 'send';
        } else if (voice) {
          confirmed = await showModalBottomSheet<String>(
            context: context,
            isScrollControlled: true,
            showDragHandle: true,
            builder: (context) => _MediaPreviewGuard(
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    20,
                    0,
                    20,
                    16 + MediaQuery.viewInsetsOf(context).bottom,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        tr(
                          context,
                          pending.music ? 'Send music' : 'Send audio',
                          pending.music ? 'ارسال موسیقی' : 'ارسال صدا',
                        ),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 12),
                      if (pending.music)
                        LoomMusicPreview(file: file)
                      else
                        LoomAudioTile(
                          file: file,
                          title: file.uri.pathSegments.last,
                          waveform: pending.waveform,
                          music: pending.music,
                        ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: caption,
                              minLines: 1,
                              maxLines: 3,
                              maxLength: 2000,
                              decoration: InputDecoration(
                                counterText: '',
                                hintText: tr(
                                  context,
                                  'Add a caption',
                                  'افزودن توضیح',
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          IconButton.filled(
                            tooltip: tr(context, 'Send', 'ارسال'),
                            icon: const Icon(LoomIcons.arrow_upward),
                            onPressed: () => Navigator.pop(context, 'send'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        } else {
          confirmed = await Navigator.push<String>(
            context,
            MaterialPageRoute(
              builder: (context) => _MediaPreviewGuard(
                child: Scaffold(
                  appBar: LoomGlassAppBar(
                    actions: [
                      if (pending.owned &&
                          !voice &&
                          !pending.sticker &&
                          !pending.file.path.contains('loom_media_keyboard'))
                        TextButton(
                          onPressed: () => Navigator.pop(context, 'retake'),
                          child: Text(tr(context, 'Retake', 'ثبت دوباره')),
                        ),
                    ],
                    title: Text(
                      tr(
                        context,
                        voice ? 'Send audio' : 'Media preview',
                        voice ? 'ارسال صدا' : 'پیش‌نمایش مدیا',
                      ),
                    ),
                  ),
                  body: SafeArea(
                    child: Column(
                      children: [
                        Expanded(
                          child: Center(
                            child: voice
                                ? LoomAudioTile(
                                    file: file,
                                    title: pending.music
                                        ? file.uri.pathSegments.last
                                        : tr(
                                            context,
                                            'Voice message',
                                            'پیام صوتی',
                                          ),
                                    waveform: pending.waveform,
                                  )
                                : !video
                                ? InteractiveViewer(
                                    child: Image.file(
                                      file,
                                      cacheWidth: 1080,
                                      fit: BoxFit.contain,
                                      errorBuilder: (_, _, _) => const Icon(
                                        LoomIcons.broken_image_outlined,
                                      ),
                                    ),
                                  )
                                : _LocalVideoPreview(file: file, round: false),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: Row(
                            children: [
                              Expanded(
                                child: LoomComposerKeyboard(
                                  controller: caption,
                                  onSend: () => Navigator.pop(context, 'send'),
                                  child: TextField(
                                    controller: caption,
                                    minLines: 1,
                                    maxLines: 3,
                                    maxLength: 2000,
                                    decoration: InputDecoration(
                                      hintText: tr(
                                        context,
                                        'Add a caption',
                                        'افزودن توضیح',
                                      ),
                                      counterText: '',
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              IconButton.filled(
                                tooltip: tr(context, 'Send', 'ارسال'),
                                icon: const Icon(LoomIcons.arrow_upward),
                                onPressed: () => Navigator.pop(context, 'send'),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        }
        if (confirmed == 'retake' &&
            mounted &&
            widget.conversation?.id == conversation.id &&
            !LoomAppLock.instance.locked) {
          composer.text = caption.text;
          messaging.discardPendingMedia();
          setState(() => _uploading = false);
          _mediaPreviewOpen = false;
          await _sendAttachment(
            pending.kind == 'video_note'
                ? 'video_note'
                : video
                ? 'camera_video'
                : 'camera',
          );
          return;
        }
        if (confirmed != 'send' ||
            messaging.pendingMedia != pending ||
            !mounted ||
            widget.conversation?.id != conversation.id ||
            LoomAppLock.instance.locked) {
          return;
        }
        final submitted = composer.value;
        setState(() => _uploading = true);
        // Give the progress surface a frame before preparation/encryption.
        await WidgetsBinding.instance.endOfFrame;
        prepared = await LoomMediaPreparation.prepare(
          file,
          pending.kind,
          sticker: pending.sticker,
        );
        file = prepared.file;
        if (!mounted ||
            messaging.pendingMedia != pending ||
            widget.conversation?.id != conversation.id ||
            LoomAppLock.instance.locked) {
          return;
        }
        if (await file.length() > messaging.mediaUploadLimit) {
          if (mounted) {
            _showComingSoon(
              context,
              tr(
                context,
                'Server file limit: ${(messaging.mediaUploadLimit / 1048576).toStringAsFixed(1)} MiB. Your draft is kept.',
                'سقف فایل سرور: ${(messaging.mediaUploadLimit / 1048576).toStringAsFixed(1)} مگابایت؛ پیش‌نویس حفظ شد.',
              ),
            );
          }
          return;
        }
        final ok = await messaging.sendMedia(
          conversation.id,
          file,
          pending.kind,
          caption: caption.text,
          music: pending.music,
          sticker: pending.sticker,
          waveform: pending.waveform,
          reply: reply,
        );
        if (ok && messaging.pendingMedia == pending) {
          messaging.discardPendingMedia();
        }
        if (ok && widget.drafts.replies[conversation.id] == reply) {
          widget.drafts.replies.remove(conversation.id);
        }
        if (ok &&
            !pending.sticker &&
            mounted &&
            widget.conversation?.id == conversation.id &&
            composer.text == submitted.text) {
          composer.clear();
        }
        if (!ok && mounted) {
          _showComingSoon(
            context,
            tr(
              context,
              'Media was not sent; your draft is kept.',
              'مدیا ارسال نشد؛ پیش‌نویس حفظ شد.',
            ),
          );
        }
      } finally {
        caption.dispose();
        if (mounted) {
          setState(() => _uploading = false);
        }
      }
    } catch (_) {
      if (mounted) {
        _showComingSoon(
          context,
          tr(
            context,
            'Could not prepare or send this media. Your draft is kept; try again.',
            'آماده‌سازی یا ارسال مدیا ممکن نشد؛ پیش‌نویس حفظ شد، دوباره تلاش کنید.',
          ),
        );
      }
    } finally {
      _mediaPreviewOpen = false;
      if (voice && LoomPlaybackController.voice.isSource(file)) {
        await LoomPlaybackController.voice.close();
      }
      await prepared?.dispose();
      if (mounted) {
        setState(() => _uploading = false);
      }
    }
  }

  Rect? _attachmentOrigin;

  Future<void> _attach() async {
    if (_uploading) return;
    final draftId = _draftId;
    final address = widget.messaging?.onboarding.receipt?.address;
    if (draftId == null) return;
    final target = widget.conversation;
    final session = widget.messaging;
    final submitted = composer.value;
    final gallery = widget.drafts.galleries.putIfAbsent(
      draftId,
      () => _GalleryDraft(composer.text),
    );
    if (!gallery.replyCaptured) {
      gallery.reply = widget.drafts.replies[draftId];
      gallery.replyCaptured = true;
    }
    bool authorized() =>
        mounted && draftId == _draftId && !LoomAppLock.instance.locked;
    final choice = await showLoomSurface<String>(
      context: context,
      origin: _attachmentOrigin,
      identity: ('attachment-gallery', draftId),
      builder: (_) => _AttachmentGallery(
        draft: gallery,
        authorized: authorized,
        canShareAddress: address != null,
        send: (item, caption) async {
          if (!authorized() || target == null || session == null) return false;
          final source = await item.resolve();
          if (source == null || !authorized()) return false;
          LoomPreparedMedia? prepared;
          try {
            prepared = await LoomMediaPreparation.prepare(source, item.kind);
            if (!authorized() ||
                await prepared.file.length() > session.mediaUploadLimit) {
              return false;
            }
            final ok = await session.sendMedia(
              target.id,
              prepared.file,
              item.kind,
              caption: caption,
              reply: gallery.reply,
            );
            if (ok && widget.drafts.replies[target.id] == gallery.reply) {
              widget.drafts.replies.remove(target.id);
            }
            return ok;
          } finally {
            await prepared?.dispose();
          }
        },
      ),
    );
    if (choice == 'queued') {
      if (mounted && draftId == _draftId) {
        if (composer.text == submitted.text) composer.clear();
        setState(() {});
      }
      return;
    }
    if (choice == 'sent') {
      if (mounted && draftId == _draftId && composer.text == submitted.text) {
        composer.clear();
      }
      widget.drafts.galleries.remove(draftId);
      gallery.dispose();
      if (mounted) setState(() {});
      return;
    }
    if (!mounted || draftId != _draftId || choice == null) {
      return;
    }
    if (const [
      'photo',
      'video',
      'camera',
      'camera_video',
      'voice',
      'music',
      'file',
      'gif',
      'video_note',
      'location',
      'live',
    ].contains(choice)) {
      await _sendAttachment(choice);
      return;
    }
    String? value;
    try {
      value = choice == 'contact'
          ? address
          : (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    } catch (_) {
      if (mounted) {
        _showComingSoon(
          context,
          tr(
            context,
            'Could not read the clipboard.',
            'خواندن کلیپ‌بورد ممکن نشد.',
          ),
        );
      }
      return;
    }
    if (!mounted || draftId != _draftId) {
      return;
    }
    if (value == null || value.trim().isEmpty) {
      _showComingSoon(
        context,
        tr(context, 'Your clipboard has no text.', 'کلیپ‌بورد متنی ندارد.'),
      );
      return;
    }
    final selection = composer.selection;
    final start = selection.isValid ? selection.start : composer.text.length;
    final end = selection.isValid ? selection.end : composer.text.length;
    final next = composer.text.replaceRange(start, end, value);
    if (next.length > 32000) {
      _showComingSoon(
        context,
        tr(
          context,
          'This text is too long for one message.',
          'این متن برای یک پیام بیش از حد طولانی است.',
        ),
      );
      return;
    }
    composer.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: start + value.length),
    );
    composerFocus.requestFocus();
  }

  Future<void> _call() async {
    if (calling) {
      return;
    }
    final conversation = widget.conversation;
    if (conversation?.kind == models.LoomConversationKind.group) {
      // The group branch never set `calling`, so a rapid double-tap pushed
      // two call routes; mark busy for the duration of the push.
      setState(() => calling = true);
      try {
        await showLoomGroupCall(context, conversation!.id);
      } finally {
        if (mounted) {
          setState(() => calling = false);
        }
      }
      return;
    }
    final kind = await _chooseConversationCall(
      context,
      conversation == null
          ? LoomPreviewData.conversations.first.name
          : _conversationTitle(context, conversation),
      enabled: conversation != null,
    );
    if (!mounted ||
        kind == null ||
        conversation == null ||
        conversation.id != widget.conversation?.id ||
        calling) {
      return;
    }
    setState(() => calling = true);
    try {
      await startConversationCallFromUi(context, conversation, kind);
    } finally {
      if (mounted) {
        setState(() => calling = false);
      }
    }
  }

  void _reply(LoomVisibleMessage message) {
    final id = widget.conversation?.id;
    if (id == null || !message.readable) {
      return;
    }
    setState(() => widget.drafts.replies[id] = message);
    composerFocus.requestFocus();
  }

  Future<void> _messageActions(LoomVisibleMessage message) async {
    final id = widget.conversation?.id;
    final action = await _chooseMessageAction(
      context,
      message,
      origin: LoomOrigin.of(
        _messageKeys[message.record.clientId]?.currentContext,
      ),
    );
    if (!mounted || id != widget.conversation?.id) {
      return;
    }
    if (action == 'delete' && id != null && widget.messaging != null) {
      if (!await _confirmLocalDeletion(context) ||
          !mounted ||
          id != widget.conversation?.id) {
        return;
      }
      await widget.messaging!.deleteLocalMessage(id, message.record.clientId);
      if (!mounted) return;
      setState(() {
        if (widget.drafts.replies[id]?.record.clientId ==
            message.record.clientId) {
          widget.drafts.replies.remove(id);
        }
      });
    }
    if (action == 'reply') {
      _reply(message);
    }
    if (action == 'select') {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(tr(context, 'Select text', 'انتخاب متن')),
          content: SingleChildScrollView(child: SelectableText(message.text)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(tr(context, 'Done', 'تمام')),
            ),
          ],
        ),
      );
    }
    if (action == 'copy') {
      try {
        await Clipboard.setData(ClipboardData(text: message.text));
        if (mounted) {
          _showComingSoon(
            context,
            tr(context, 'Message copied', 'پیام کپی شد'),
          );
        }
      } catch (_) {
        if (mounted) {
          _showComingSoon(
            context,
            tr(context, 'Could not copy this message.', 'کپی پیام انجام نشد.'),
          );
        }
      }
    }
  }

  void _profile() {
    final conversation = widget.conversation;
    if (conversation == null) {
      return;
    }
    if (conversation.kind == models.LoomConversationKind.group) {
      Navigator.push<void>(
        context,
        MaterialPageRoute<void>(
          builder: (_) => LoomGroupsScreen(
            initialGroupId: conversation.id,
            managementOnly: true,
          ),
        ),
      );
      return;
    }
    final address = conversation.peerAddress;
    if (conversation.kind == models.LoomConversationKind.direct &&
        address != null) {
      Navigator.push<void>(
        context,
        MaterialPageRoute<void>(
          builder: (_) => LoomPeerProfileScreen(
            address: address,
            displayName: _conversationTitle(context, conversation),
            identityId: widget.messaging?.peerIdentityId(address),
            conversationId: conversation.id,
            messaging: widget.messaging,
            mediaBuilder: (message) =>
                message.content.attachment?['kind'] == 'audio'
                ? _RichMessageContent(
                    message: message,
                    messaging: widget.messaging,
                  )
                : _SharedMediaThumbnail(message: message),
          ),
        ),
      );
    } else if (conversation.kind == models.LoomConversationKind.self) {
      Navigator.pushNamed(context, '/profile');
    } else {
      Navigator.push<void>(
        context,
        MaterialPageRoute<void>(
          builder: (_) => Scaffold(
            appBar: LoomGlassAppBar(
              title: Text(tr(context, 'Conversation details', 'جزئیات گفتگو')),
            ),
            body: _DetailsPane(
              preview: false,
              messaging: widget.messaging,
              conversation: conversation,
            ),
          ),
        ),
      );
    }
  }

  LoomPeerPresence? get _peerPresence => widget.conversation == null
      ? null
      : widget.messaging?.presenceFor(widget.conversation!.id);

  bool get _peerOnline =>
      _peerPresence?.online == true &&
      _peerPresence!.isFresh &&
      widget.messaging?.status == LoomMessagingSessionStatus.ready;

  String _presenceLabel(BuildContext context) {
    if (widget.preview || _peerOnline) {
      return tr(context, 'online', 'آنلاین');
    }
    final conversation = widget.conversation;
    if (conversation?.kind == models.LoomConversationKind.self) {
      return tr(context, 'Your private space', 'فضای شخصی شما');
    }
    final seen = _peerPresence?.lastSeenAt?.toLocal();
    if (seen == null) {
      return tr(context, 'Last seen unavailable', 'آخرین بازدید در دسترس نیست');
    }
    final localizations = MaterialLocalizations.of(context);
    final time = localizations.formatTimeOfDay(
      TimeOfDay.fromDateTime(seen),
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    );
    final day = DateUtils.isSameDay(seen, DateTime.now())
        ? ''
        : '${localizations.formatShortDate(seen)} · ';
    return tr(context, 'last seen $day$time', 'آخرین بازدید $day$time');
  }

  Future<void> _deleteChat() async {
    final id = widget.conversation?.id;
    final messaging = widget.messaging;
    if (id == null ||
        messaging == null ||
        !await _confirmLocalDeletion(context, chat: true)) {
      return;
    }
    if (!mounted || id != widget.conversation?.id) return;
    await messaging.deleteLocalConversation(id);
    widget.drafts.remove(id);
    widget.drafts.replies.remove(id);
    widget.drafts.galleries.remove(id)?.dispose();
    if (mounted) widget.onBack?.call();
  }

  void _menuAction(String action) {
    final conversation = widget.conversation;
    final messaging = widget.messaging;
    if (const [
          'archive',
          'pin',
          'mute',
          'read',
          'unread',
          'clear',
        ].contains(action) &&
        conversation != null &&
        messaging != null) {
      unawaited(_manageConversation(context, action, conversation, messaging));
      if (action == 'archive') widget.onBack?.call();
      return;
    }
    switch (action) {
      case 'delete':
        unawaited(_deleteChat());
        break;
      case 'call':
        unawaited(_call());
        break;
      case 'wallpaper':
        final target = widget.conversation;
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => LoomWallpaperEditor(
              chatId: target == null
                  ? null
                  : '${widget.messaging?.onboarding.committedIdentity?.identityId}:${target.id}',
            ),
          ),
        );
        break;
      case 'appearance':
        Navigator.pushNamed(context, '/settings/appearance');
        break;
      case 'guide':
        unawaited(_showDeliveryGuide(context));
        break;
      case 'search':
        setState(() {
          searching = true;
          query = '';
        });
        break;
      case 'details':
        if (conversation?.kind == models.LoomConversationKind.group) {
          _profile();
          break;
        }
        final toggle = widget.onToggleDetails;
        if (toggle != null) {
          toggle();
        } else {
          _profile();
        }
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    _scheduleRead();
    final conversation = widget.conversation;
    final messaging = widget.messaging;
    final preview = widget.preview;
    final name = preview
        ? LoomPreviewData.conversations.first.name
        : conversation == null
        ? tr(context, 'Conversation', 'گفتگو')
        : _conversationTitle(context, conversation);
    final canCall =
        preview ||
        conversation?.kind == models.LoomConversationKind.direct ||
        (conversation?.kind == models.LoomConversationKind.group &&
            LoomGroupCallScope.maybeOf(context) != null);
    final reply = widget.drafts.replies[conversation?.id];
    final canCompose =
        preview ||
        (conversation != null &&
            (conversation.kind != models.LoomConversationKind.group ||
                (messaging?.canSendToGroup(conversation.id) ?? false)));
    final needle = query.trim().toLowerCase();
    final allMessages = conversation == null || messaging == null
        ? const <LoomVisibleMessage>[]
        : messaging.visibleMessagesFor(conversation.id);
    final messages = needle.isEmpty
        ? allMessages
        : allMessages
              .where(
                (m) =>
                    needle.isEmpty ||
                    (m.readable && m.text.toLowerCase().contains(needle)),
              )
              .toList(growable: false);
    _messageIndexes.clear();
    for (var index = 0; index < messages.length; index++) {
      _messageIndexes[messages[index].record.clientId] = index;
    }
    final previewMessages = LoomPreviewData.messages
        .where((m) => needle.isEmpty || m.text.toLowerCase().contains(needle))
        .toList(growable: false);

    final topInset = MediaQuery.paddingOf(context).top;
    final headerInset =
        topInset + 24.0 + MediaQuery.textScalerOf(context).scale(40);
    final header = _ConversationHeader(
      conversation: conversation,
      archived: conversation == null
          ? false
          : messaging?.isArchived(conversation.id) ?? false,
      name: name,
      saved: conversation?.kind == models.LoomConversationKind.self,
      status: conversation?.kind == models.LoomConversationKind.self
          ? null
          : conversation?.kind == models.LoomConversationKind.group
          ? tr(
              context,
              '${messaging?.groupsController?.groups.where((g) => g.id == conversation?.id).firstOrNull?.members.map((m) => m.accountId).toSet().length ?? 0} members',
              '${messaging?.groupsController?.groups.where((g) => g.id == conversation?.id).firstOrNull?.members.map((m) => m.accountId).toSet().length ?? 0} عضو',
            )
          : _presenceLabel(context),
      online: _peerOnline,
      avatar: conversation?.kind == models.LoomConversationKind.group
          ? LoomGroupAvatar(
              groupId: conversation!.id,
              label: name,
              size: 36,
              groups: messaging?.groupsController,
            )
          : LoomOwnAvatar(
              name: name,
              identityId: messaging?.peerIdentityId(conversation?.peerAddress),
              size: 36,
            ),
      onBack: widget.onBack == null
          ? null
          : () {
              FocusManager.instance.primaryFocus?.unfocus();
              widget.onBack!();
            },
      onProfile: conversation == null ? null : _profile,
      onSearch: () => _menuAction('search'),
      onCall: canCall && !calling ? () => unawaited(_call()) : null,
      onMenu: _menuAction,
    );
    return LoomWallpaperBackdrop(
      chatId: conversation == null
          ? null
          : '${messaging?.onboarding.committedIdentity?.identityId}:${conversation.id}',
      child: Stack(
        children: [
          Column(
            children: [
              if (conversation?.kind == models.LoomConversationKind.group &&
                  messaging?.groupsController?.error != null)
                Padding(
                  padding: EdgeInsets.fromLTRB(12, headerInset + 12, 12, 4),
                  child: MaterialBanner(
                    content: Text(
                      messaging!.groupsController!.error!,
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => messaging.groupsController!.open(),
                        child: Text(tr(context, 'Retry', 'تلاش مجدد')),
                      ),
                    ],
                  ),
                ),
              AnimatedSwitcher(
                duration: LoomAccessibility.fromContext(context).reduceMotion
                    ? Duration.zero
                    : const Duration(milliseconds: 240),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (child, animation) => SizeTransition(
                  sizeFactor: animation,
                  alignment: Alignment.topCenter,
                  child: FadeTransition(opacity: animation, child: child),
                ),
                child: !searching
                    ? const SizedBox.shrink(key: ValueKey('search-closed'))
                    : Padding(
                        padding: EdgeInsets.fromLTRB(
                          10,
                          headerInset + 8,
                          10,
                          10,
                        ),
                        child: TextField(
                          key: ValueKey(
                            'message-search-${conversation?.id ?? "preview"}',
                          ),
                          autofocus: true,
                          onChanged: (value) => setState(() => query = value),
                          decoration: InputDecoration(
                            hintText: tr(
                              context,
                              'Search loaded messages',
                              'جستجو در پیام‌های بارگذاری‌شده',
                            ),
                            prefixIcon: const Icon(LoomIcons.search_rounded),
                            suffixIcon: IconButton(
                              tooltip: MaterialLocalizations.of(
                                context,
                              ).closeButtonLabel,
                              icon: const Icon(LoomIcons.close_rounded),
                              onPressed: () => setState(() {
                                composerFocus.unfocus();
                                FocusManager.instance.primaryFocus?.unfocus();
                                searching = false;
                                query = '';
                              }),
                            ),
                          ),
                        ),
                      ),
              ),
              Expanded(
                child: LoomComposerOverlay(
                  historyBuilder: (context, bottomExtent) => Stack(
                    children: [
                      Positioned.fill(
                        child: conversation == null && !preview
                            ? _ConversationEmpty(
                                onNewChat: () => Navigator.push<void>(
                                  context,
                                  MaterialPageRoute<void>(
                                    builder: (_) => const LoomPeopleScreen(),
                                  ),
                                ),
                              )
                            : (preview
                                  ? previewMessages.isEmpty
                                  : messages.isEmpty)
                            ? Center(
                                child: Padding(
                                  padding: const EdgeInsets.all(24),
                                  child: Text(
                                    needle.isNotEmpty
                                        ? tr(
                                            context,
                                            'No matching messages',
                                            'پیامی پیدا نشد',
                                          )
                                        : tr(
                                            context,
                                            'No messages yet.',
                                            'هنوز پیامی نیست.',
                                          ),
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                              )
                            : ListView.builder(
                                key: PageStorageKey(
                                  'messages-${_draftId ?? "empty"}',
                                ),
                                controller: messageScroll,
                                reverse: true,
                                keyboardDismissBehavior:
                                    ScrollViewKeyboardDismissBehavior.onDrag,
                                padding: EdgeInsets.fromLTRB(
                                  12,
                                  searching ? 12 : headerInset + 16,
                                  12,
                                  bottomExtent + 12,
                                ),
                                itemCount: preview
                                    ? previewMessages.length
                                    : messages.length +
                                          (needle.isEmpty &&
                                                  conversation != null &&
                                                  (messaging?.hasOlderMessages(
                                                        conversation.id,
                                                      ) ??
                                                      false)
                                              ? 1
                                              : 0),
                                findChildIndexCallback: preview
                                    ? null
                                    : (key) {
                                        if (key is! ValueKey<String>) {
                                          return null;
                                        }
                                        return _messageIndexes[key.value];
                                      },
                                itemBuilder: (context, index) {
                                  if (!preview && index == messages.length) {
                                    return Center(
                                      child: TextButton.icon(
                                        key: ValueKey(
                                          'history-${conversation!.id}',
                                        ),
                                        onPressed:
                                            messaging!.loadingOlderMessages(
                                              conversation.id,
                                            )
                                            ? null
                                            : () => messaging.loadOlderMessages(
                                                conversation.id,
                                              ),
                                        icon:
                                            messaging.loadingOlderMessages(
                                              conversation.id,
                                            )
                                            ? const SizedBox.square(
                                                dimension: 16,
                                                child:
                                                    CircularProgressIndicator(
                                                      strokeWidth: 2,
                                                    ),
                                              )
                                            : const Icon(
                                                LoomIcons.history_rounded,
                                              ),
                                        label: Text(
                                          tr(
                                            context,
                                            'Load earlier messages',
                                            'بارگذاری پیام‌های قدیمی‌تر',
                                          ),
                                        ),
                                      ),
                                    );
                                  }
                                  if (preview) {
                                    final message = previewMessages[index];
                                    return LoomMessageBubble(
                                      text: message.text,
                                      time: message.time,
                                      mine: message.mine,
                                    );
                                  }
                                  final message = messages[index];
                                  final date = DateUtils.dateOnly(
                                    message.record.createdAt.toLocal(),
                                  );
                                  final showDate =
                                      index == messages.length - 1 ||
                                      date !=
                                          DateUtils.dateOnly(
                                            messages[index + 1].record.createdAt
                                                .toLocal(),
                                          );
                                  final quote = message.content.reply;
                                  final quotedId =
                                      message.record.replyToMessageId;
                                  final quoted = quote != null
                                      ? _messagesByClientId[quote['clientId']]
                                      : _messagesById[quotedId];
                                  return LoomSendReveal(
                                    key: ValueKey(message.record.clientId),
                                    outgoing:
                                        message.record.senderAddress ==
                                        messaging!.onboarding.receipt?.address,
                                    animate:
                                        index < 4 &&
                                        _enteringMessages.contains(
                                          message.record.clientId,
                                        ),
                                    onEnd: () => _enteringMessages.remove(
                                      message.record.clientId,
                                    ),
                                    child: KeyedSubtree(
                                      key: _messageKeys.putIfAbsent(
                                        message.record.clientId,
                                        () => GlobalKey(),
                                      ),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.stretch,
                                        children: [
                                          if (showDate &&
                                              message
                                                      .record
                                                      .metadata['groupTimestampKnown'] !=
                                                  false)
                                            _MessageDayLabel(date: date),
                                          _LiveMessageBubble(
                                            message: message,
                                            grouped:
                                                !showDate &&
                                                index + 1 < messages.length &&
                                                messages[index + 1]
                                                        .record
                                                        .senderAddress ==
                                                    message
                                                        .record
                                                        .senderAddress &&
                                                message.record.createdAt
                                                        .difference(
                                                          messages[index + 1]
                                                              .record
                                                              .createdAt,
                                                        )
                                                        .abs() <
                                                    const Duration(minutes: 5),
                                            highlighted:
                                                _highlighted ==
                                                message.record.clientId,
                                            onQuoteTap: quoted == null
                                                ? null
                                                : () => unawaited(
                                                    _jumpToReply(
                                                      quoted.record.clientId,
                                                    ),
                                                  ),
                                            onActions: () =>
                                                _messageActions(message),
                                            onReply: message.readable
                                                ? () => _reply(message)
                                                : null,
                                            quotedText:
                                                quotedId == null &&
                                                    quote == null
                                                ? null
                                                : message.content
                                                          .resolvedReplyExcerpt(
                                                            quoted?.readable ==
                                                                    true
                                                                ? quoted!
                                                                      .content
                                                                      .replyExcerpt
                                                                : null,
                                                          ) ??
                                                      tr(
                                                        context,
                                                        'Original message unavailable',
                                                        'پیام اصلی در دسترس نیست',
                                                      ),
                                            quotedAuthor: quote == null
                                                ? null
                                                : quote['sender'] ==
                                                      messaging
                                                          .onboarding
                                                          .receipt
                                                          ?.address
                                                ? tr(context, 'You', 'شما')
                                                : conversation?.title ??
                                                      tr(
                                                        context,
                                                        'Reply',
                                                        'پاسخ',
                                                      ),
                                            content:
                                                message.readable &&
                                                    (message
                                                                .content
                                                                .attachment !=
                                                            null ||
                                                        message
                                                                .content
                                                                .location !=
                                                            null)
                                                ? _RichMessageContent(
                                                    message: message,
                                                    messaging: messaging,
                                                  )
                                                : null,
                                            ownAddress: messaging
                                                .onboarding
                                                .receipt
                                                ?.address,
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),
                      ),
                      PositionedDirectional(
                        end: 12,
                        bottom: bottomExtent + 12,
                        child: ListenableBuilder(
                          listenable: messageScroll,
                          builder: (context, _) {
                            final show =
                                messageScroll.hasClients &&
                                messageScroll.offset > 160;
                            return AnimatedScale(
                              scale: show ? 1 : 0,
                              duration: _motionDuration(
                                context,
                                LoomMotion.component.inMilliseconds,
                              ),
                              curve: show
                                  ? LoomMotion.emphasized
                                  : LoomMotion.exit,
                              alignment: AlignmentDirectional.bottomEnd.resolve(Directionality.of(context)),
                              child: AnimatedOpacity(
                                opacity: show ? 1 : 0,
                                duration: _motionDuration(
                                  context,
                                  LoomMotion.component.inMilliseconds,
                                ),
                                child: show
                                    ? LoomGlassSurface(
                                        liveBackdrop: true,
                                        radius: 28,
                                        child: IconButton(
                                          tooltip: tr(
                                            context,
                                            'Latest messages',
                                            'آخرین پیام‌ها',
                                          ),
                                          onPressed: () {
                                            if (LoomAccessibility.fromContext(
                                              context,
                                            ).reduceMotion) {
                                              messageScroll.jumpTo(0);
                                            } else {
                                              unawaited(
                                                messageScroll.animateTo(
                                                  0,
                                                  duration: const Duration(
                                                    milliseconds: 260,
                                                  ),
                                                  curve: Curves.easeOutCubic,
                                                ),
                                              );
                                            }
                                          },
                                          icon: const Icon(
                                            LoomIcons
                                                .keyboard_arrow_down_rounded,
                                          ),
                                        ),
                                      )
                                    : const SizedBox(width: 48, height: 48),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                  composer: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (messaging?.pendingMedia != null &&
                          messaging!.pendingMedia!.conversationId ==
                              conversation?.id)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(10, 4, 10, 0),
                          child: LoomGlassSurface(
                            liveBackdrop: true,
                            radius: 16,
                            child: ListTile(
                              leading: const Icon(LoomIcons.attachment),
                              title: Text(
                                tr(
                                  context,
                                  sending
                                      ? 'Preparing media for sending…'
                                      : 'Selected media is ready',
                                  sending
                                      ? 'آماده‌سازی مدیا برای ارسال…'
                                      : 'مدیای انتخاب‌شده آماده است',
                                ),
                              ),
                              subtitle: Text(
                                tr(
                                  context,
                                  sending
                                      ? 'Your draft is kept until it is queued'
                                      : defaultTargetPlatform ==
                                            TargetPlatform.windows
                                      ? 'Click to preview and send'
                                      : 'Tap to preview and send',
                                  sending
                                      ? 'پیش‌نویس تا قرار گرفتن در صف حفظ می‌شود'
                                      : 'برای پیش‌نمایش و ارسال بزنید',
                                ),
                              ),
                              onTap: sending ? null : _previewPendingMedia,
                              trailing: IconButton(
                                tooltip: tr(context, 'Discard', 'حذف انتخاب'),
                                onPressed: sending || _mediaPreviewOpen
                                    ? null
                                    : messaging.discardPendingMedia,
                                icon: const Icon(LoomIcons.close),
                              ),
                            ),
                          ),
                        ),
                      AnimatedSize(
                        duration:
                            LoomAccessibility.fromContext(context).reduceMotion
                            ? Duration.zero
                            : LoomMotion.component,
                        alignment: Alignment.bottomCenter,
                        child: reply == null
                            ? const SizedBox.shrink()
                            : Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  10,
                                  4,
                                  10,
                                  0,
                                ),
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: context.loom.surfaceElevated,
                                    borderRadius: BorderRadius.circular(12),
                                    border: BorderDirectional(
                                      start: BorderSide(
                                        color: context.loom.primary,
                                        width: 3,
                                      ),
                                    ),
                                  ),
                                  padding: const EdgeInsetsDirectional.only(
                                    start: 12,
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(
                                        LoomIcons.reply_rounded,
                                        color: context.loom.primary,
                                        size: 20,
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              tr(
                                                context,
                                                'Replying to',
                                                'در پاسخ به',
                                              ),
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .labelMedium
                                                  ?.copyWith(
                                                    color: context.loom.primary,
                                                  ),
                                            ),
                                            Text(
                                              reply.text,
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                              style: Theme.of(
                                                context,
                                              ).textTheme.bodySmall,
                                            ),
                                          ],
                                        ),
                                      ),
                                      IconButton(
                                        tooltip: tr(
                                          context,
                                          'Cancel reply',
                                          'لغو پاسخ',
                                        ),
                                        onPressed: () => setState(
                                          () => widget.drafts.replies.remove(
                                            conversation?.id,
                                          ),
                                        ),
                                        icon: const Icon(
                                          LoomIcons.close_rounded,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                      ),
                      if (_uploading)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(48, 8, 12, 4),
                          child: ListTile(
                            leading: const SizedBox.square(
                              dimension: 24,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            title: Text(
                              tr(
                                context,
                                'Sending media…',
                                'در حال ارسال مدیا…',
                              ),
                            ),
                            subtitle: Text(
                              tr(
                                context,
                                'You can keep typing',
                                'می‌توانید به نوشتن ادامه دهید',
                              ),
                            ),
                          ),
                        ),
                      if (widget.drafts.galleries[conversation?.id]
                          case final gallery?)
                        _MediaBatchProgress(
                          batch: gallery.batch,
                          builder: (context) {
                            final batch = gallery.batch;
                            if (batch.pending.isEmpty && !batch.sending) {
                              return const SizedBox.shrink();
                            }
                            return Align(
                              alignment: AlignmentDirectional.centerEnd,
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  48,
                                  8,
                                  12,
                                  4,
                                ),
                                child: Material(
                                  color: context.loom.surfaceElevated,
                                  borderRadius: BorderRadius.circular(20),
                                  child: ListTile(
                                    dense: true,
                                    leading: batch.sending
                                        ? const SizedBox.square(
                                            dimension: 24,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                            ),
                                          )
                                        : const Icon(LoomIcons.refresh_rounded),
                                    title: Text(
                                      batch.sending
                                          ? tr(
                                              context,
                                              'Sending media…',
                                              'در حال ارسال مدیا…',
                                            )
                                          : tr(
                                              context,
                                              'Media kept for retry',
                                              'مدیا برای تلاش دوباره حفظ شد',
                                            ),
                                    ),
                                    subtitle: Text(
                                      batch.sending
                                          ? '${batch.completed} / ${batch.total}'
                                          : tr(
                                              context,
                                              'Tap to review and retry',
                                              'برای بررسی و تلاش دوباره بزنید',
                                            ),
                                    ),
                                    onTap: batch.sending ? null : _attach,
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      if (preview || conversation != null)
                        Padding(
                          padding: EdgeInsets.fromLTRB(
                            10,
                            4,
                            10,
                            4 + MediaQuery.paddingOf(context).bottom,
                          ),
                          child: _InlineVoiceComposer(
                            key: ValueKey(
                              'voice-${conversation?.id ?? "preview"}',
                            ),
                            controller: composer,
                            focusNode: composerFocus,
                            enabled: canCompose,
                            sending: sending,
                            onContentInserted:
                                !preview && canCompose && !_uploading
                                ? (content) =>
                                      unawaited(_insertKeyboardMedia(content))
                                : null,
                            onSend: preview ? null : _send,
                            onAttach: canCompose && !_uploading
                                ? _attach
                                : null,
                            onAttachmentOrigin: (rect) =>
                                _attachmentOrigin = rect,
                            onVideoSend: (file, duration) async {
                              final target = conversation;
                              final session = messaging;
                              if (preview ||
                                  !canCompose ||
                                  target == null ||
                                  session == null ||
                                  !mounted ||
                                  widget.conversation?.id != target.id ||
                                  LoomAppLock.instance.locked) {
                                return false;
                              }
                              final reply = widget.drafts.replies[target.id];
                              final ok = await session.sendMedia(
                                target.id,
                                file,
                                'video_note',
                                duration: duration,
                                reply: reply,
                              );
                              if (ok &&
                                  widget.drafts.replies[target.id] == reply) {
                                widget.drafts.replies.remove(target.id);
                              }
                              return ok;
                            },
                            onVoiceSend: (file, peaks, duration) async {
                              final target = conversation;
                              final session = messaging;
                              if (target == null ||
                                  session == null ||
                                  !mounted ||
                                  widget.conversation?.id != target.id ||
                                  LoomAppLock.instance.locked) {
                                return false;
                              }
                              final reply = widget.drafts.replies[target.id];
                              final ok = await session.sendMedia(
                                target.id,
                                file,
                                'audio',
                                waveform: peaks,
                                duration: duration,
                                reply: reply,
                              );
                              if (ok &&
                                  widget.drafts.replies[target.id] == reply) {
                                widget.drafts.replies.remove(target.id);
                              }
                              if (mounted) setState(() {});
                              return ok;
                            },
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: LoomTopGlassFade(height: headerInset + 32),
          ),
          PositionedDirectional(
            top: topInset + 8,
            start: 10,
            end: 10,
            child: header,
          ),
        ],
      ),
    );
  }
}

class _MessageDayLabel extends StatelessWidget {
  const _MessageDayLabel({required this.date});
  final DateTime date;

  @override
  Widget build(BuildContext context) {
    final today = DateUtils.dateOnly(DateTime.now());
    final label = date == today
        ? tr(context, 'Today', 'امروز')
        : date == DateTime(today.year, today.month, today.day - 1)
        ? tr(context, 'Yesterday', 'دیروز')
        : MaterialLocalizations.of(context).formatMediumDate(date);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: LoomGlassSurface(
          blur: false,
          radius: LoomRadii.pill,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          child: Text(label, style: Theme.of(context).textTheme.labelSmall),
        ),
      ),
    );
  }
}
