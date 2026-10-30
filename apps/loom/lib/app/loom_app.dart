import 'dev_surface_policy.dart';
import 'dart:async';

import 'package:loom_crypto_bridge/loom_crypto_bridge.dart';

import '../features/security/presentation/app_lock_gate.dart';

import 'package:loom_design/loom_design.dart';
import 'package:loom_protocol/loom_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'appearance_preferences.dart';
import '../features/groups/application/groups_controller.dart';
import '../features/groups/application/group_call_controller.dart';
import '../features/groups/presentation/group_call_screen.dart';
import '../features/groups/presentation/group_join_screen.dart';

import 'package:loom_models/loom_models.dart' show LoomGroupInviteLink;

import '../features/notifications/application/message_notifications.dart';
import 'chat_wallpaper.dart';
import '../features/media/presentation/playback_host.dart';
import '../features/media/application/playback_controller.dart';

import '../features/calls/application/call_session_controller.dart';
import '../features/calls/presentation/active_call_screen.dart';
import '../features/calls/presentation/call_surfaces.dart';
import '../features/calls/presentation/calls_screen.dart';
import '../features/chat_folders/application/chat_folder_controller.dart';
import '../features/chat_folders/presentation/chat_folders_settings_screen.dart';
import '../features/design_lab/design_lab_screen.dart';
import '../features/home/presentation/messenger_shell.dart';
import '../features/messaging/application/accepted_send_dtn_mirror.dart';
import '../features/messaging/application/messaging_session_controller.dart';
import '../features/messaging/application/nearby_dtn_service_controller.dart';
import '../features/messaging/presentation/messaging_sync_heartbeat.dart';
import '../features/nodes/application/node_directory_controller.dart';
import '../features/nodes/presentation/node_detail_screen.dart';
import '../features/onboarding/application/onboarding_controller.dart';
import '../features/onboarding/presentation/identity_creation_screen.dart';
import '../features/onboarding/presentation/link_device_screen.dart';
import '../features/onboarding/presentation/onboarding_node_selection_screen.dart';
import '../features/onboarding/presentation/ready_screen.dart';
import '../features/onboarding/presentation/recovery_screen.dart';
import '../features/onboarding/presentation/recovery_verification_screen.dart';
import '../features/onboarding/presentation/restore_identity_screen.dart';
import '../features/onboarding/presentation/sign_in_screen.dart';
import '../features/onboarding/presentation/startup_gate.dart';
import '../features/people/presentation/people_screen.dart';
import '../features/profile/presentation/profile_qr_screen.dart';
import '../features/profile/presentation/profile_screen.dart';
import '../features/security/presentation/security_screen.dart';
import '../features/settings/presentation/nearby_diagnostics_screen.dart';
import '../features/settings/presentation/nearby_mode_screen.dart';
import '../features/settings/presentation/settings_detail_screen.dart';

class LoomApp extends StatefulWidget {
  const LoomApp({super.key});

  @override
  State<LoomApp> createState() => _LoomAppState();
}

class _LoomAppState extends State<LoomApp>
    with SingleTickerProviderStateMixin {
  LoomThemeMode mode = LoomThemeMode.dark;
  LoomGlassQuality glassQuality = LoomGlassQuality.high;
  int? accent;
  LoomMotionPreference motion = LoomMotionPreference.system;
  LoomChatDensity chatDensity = LoomChatDensity.comfortable;
  /// The persisted language choice: 'en', 'fa', or 'sys' (follow the OS).
  /// New installs follow the system language; Persian users get FA out of
  /// the box instead of hunting through settings.
  String localePreference = 'sys';
  final _appearanceStore = LoomAppearancePreferencesStore();
  bool _appearanceChanged = false;

  // Theme changes crossfade instead of snapping. The previous ThemeData is
  // kept briefly and every color/radius eases into the new appearance.
  ThemeData? _themeFrom;
  AnimationController? _themeLerp;

  final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
  final LoomCallRouteObserver callRouteObserver = LoomCallRouteObserver();
  final groupCallRouteObserver = LoomGroupCallRouteObserver();
  late final LoomNodeDirectoryController nodeDirectory;
  late final LoomOnboardingController onboarding;
  late final LoomNearbyDtnServiceController nearbyDtn;
  late LoomMessagingSessionController messaging;
  late LoomCallSessionController calls;
  LoomGroupsController? groups;
  LoomGroupCallController? groupCalls;
  LoomAcceptedSendDtnMirror? _acceptedSendDtnMirror;
  late final LoomChatFolderController chatFolders;
  bool _hadCompleteSession = false;
  LoomMessageNotifications? _notifications;
  String? _pendingNotificationConversation;
  String? _pendingGroupLink;
  static const _groupLinkChannel = MethodChannel('loom/group_links');
  bool _openingGroupLink = false;

  @override
  void initState() {
    super.initState();
    nodeDirectory = LoomNodeDirectoryController();
    onboarding = LoomOnboardingController(nodes: nodeDirectory);
    nearbyDtn = LoomNearbyDtnServiceController(onboarding: onboarding);
    _createSessionControllers();
    chatFolders = LoomChatFolderController(
      identityIdProvider: () => onboarding.committedIdentity?.identityId,
    );
    onboarding.addListener(_onOnboardingChanged);
    unawaited(_loadAppearance());
    unawaited(LoomWallpaperStore.instance.load());
    _groupLinkChannel.setMethodCallHandler((call) async {
      if (call.method == 'link' && call.arguments is String) {
        _receiveGroupLink(call.arguments as String);
      }
    });
    unawaited(_initialGroupLink());
  }

  Future<void> _initialGroupLink() async {
    try {
      _receiveGroupLink(
        await _groupLinkChannel.invokeMethod<String>('initialLink'),
      );
    } on MissingPluginException {
      /* Link paste remains available on desktop. */
    } on PlatformException {
      /* No launch link. */
    }
  }

  void _receiveGroupLink(String? link) {
    if (!mounted ||
        link == null ||
        LoomGroupInviteLink.tryParse(link) == null) {
      return;
    }
    _pendingGroupLink = link;
    unawaited(_drainGroupLink());
  }

  Future<void> _drainGroupLink() async {
    final link = _pendingGroupLink;
    if (link == null ||
        _openingGroupLink ||
        !mounted ||
        LoomAppLock.instance.locked ||
        onboarding.status != LoomOnboardingStatus.complete ||
        navigatorKey.currentState == null) {
      return;
    }
    _pendingGroupLink = null;
    _openingGroupLink = true;
    try {
      await navigatorKey.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => LoomGroupJoinScreen(initialLink: link),
        ),
      );
    } finally {
      _openingGroupLink = false;
      if (_pendingGroupLink != null) unawaited(_drainGroupLink());
    }
  }

  Future<void> _loadAppearance() async {
    final saved = await _appearanceStore.load();
    if (!mounted || _appearanceChanged || saved == null) {
      return;
    }
    setState(() {
      mode = saved.theme;
      glassQuality = saved.glass;
      localePreference = saved.localePreference;
      accent = saved.accent;
      motion = saved.motion;
      chatDensity = saved.chatDensity;
    });
  }

  void _saveAppearance() {
    _appearanceChanged = true;
    unawaited(
      _appearanceStore.save(
        LoomAppearancePreferences(
          theme: mode,
          glass: glassQuality,
          localePreference: localePreference,
          accent: accent,
          motion: motion,
          chatDensity: chatDensity,
        ),
      ),
    );
  }

  void _setTheme(LoomThemeMode value) {
    _mutateWithThemeTransition(() => mode = value);
    _saveAppearance();
  }

  void _setGlass(LoomGlassQuality value) {
    setState(() => glassQuality = value);
    _saveAppearance();
  }

  void _setLocale(Locale value) {
    // Settings may hand back the resolved locale or the 'sys' sentinel.
    _mutateWithThemeTransition(
      () => localePreference =
          value.languageCode == _systemLocaleCode ? 'sys' : value.languageCode,
    );
    _saveAppearance();
  }

  void _createSessionControllers() {
    _acceptedSendDtnMirror?.dispose();
    _notifications?.dispose();
    groupCalls?.dispose();
    groups?.dispose();
    messaging = LoomMessagingSessionController(
      onboarding: onboarding,
      userSecurityClient: LoomDirectFirstUserSecurityClient(),
      nearbyMessageSender: nearbyDtn.persistOpaqueMessageForDtn,
    );
    _acceptedSendDtnMirror = LoomAcceptedSendDtnMirror(
      onboarding: onboarding,
      messagingListenable: messaging,
      conversationsProvider: () => messaging.conversations,
      messagesProvider: (conversationId) =>
          messaging.messagesFor(conversationId, limit: 100),
      dtnWriter: nearbyDtn.persistOpaqueMessageForDtn,
    );
    // DTN intake writes into the same durable message database as normal sync.
    // Kick the messaging controller immediately so an offline recipient does
    // not need to wait for a manual refresh or for Internet to return before a
    // newly received Nearby message becomes visible in the ordinary chat UI.
    nearbyDtn.onLocalInboxChanged = () => messaging.refreshLocalMessages();
    nearbyDtn.canConfirmLegacyDelivery = (clientId) => messaging
        .visibleMessages
        .values
        .expand((messages) => messages)
        .any(
          (message) => message.record.clientId == clientId && message.readable,
        );
    calls = LoomCallSessionController(
      onboarding: onboarding,
      messaging: messaging,
    );
    calls.attachLifecycleObserver();
    late final LoomGroupsController groupController;
    groupController = LoomGroupsController(
      onboarding: onboarding,
      trustedDevice: messaging.trustedGroupDevice,
      identityLabel: messaging.groupIdentityLabel,
      devicesForContact: messaging.groupDevicesForContact,
      sendAttachment: (id, file, kind, caption) => messaging.sendMedia(
        id,
        file,
        kind,
        caption: caption,
        music: kind == 'audio',
        publishContent: (content) => groupController.sendContent(id, content),
      ),
      onRead: (id) => unawaited(LoomMessageNotificationBridge().clear(id)),
      onIncoming: (id, title) {
        if (messaging.conversations
                .where((c) => c.id == id)
                .firstOrNull
                ?.isMuted ==
            true) {
          return;
        }
        unawaited(
          LoomMessageNotificationBridge().show(
            id,
            LoomAppLock.instance.locked ? 'Loom' : title,
          ),
        );
      },
    );
    groups = groupController;
    groupCalls = LoomGroupCallController(
      groups: groupController,
      otherCallActive: () => calls.hasPendingOrActiveCall,
    );
    calls.externalCallActive = () => groupCalls?.isActive ?? false;
    LoomPlaybackController.instance.blockedByCall = () =>
        calls.hasPendingOrActiveCall || (groupCalls?.isActive ?? false);
    messaging.attachGroups(groupController);
    _notifications = LoomMessageNotifications(
      messaging: messaging,
      onOpen: _openNotification,
    );
  }

  void _openNotification(String id) {
    _pendingNotificationConversation = id;
    unawaited(_drainNotification());
  }

  Future<void> _drainNotification() async {
    final id = _pendingNotificationConversation;
    if (id == null ||
        !mounted ||
        LoomAppLock.instance.locked ||
        onboarding.status != LoomOnboardingStatus.complete) {
      return;
    }
    if (id.isEmpty) {
      _pendingNotificationConversation = null;
      navigatorKey.currentState?.pushNamedAndRemoveUntil(
        '/messenger',
        (_) => false,
      );
      return;
    }
    await groups?.open();
    if (!mounted || LoomAppLock.instance.locked) return;
    if (groups?.groups.any((g) => g.id == id) == true) {
      _pendingNotificationConversation = null;
      navigatorKey.currentState?.pushNamedAndRemoveUntil(
        '/messenger',
        (_) => false,
        arguments: id,
      );
      return;
    }
    if (!messaging.conversations.any((c) => c.id == id)) await messaging.open();
    if (!mounted ||
        LoomAppLock.instance.locked ||
        !messaging.conversations.any((c) => c.id == id)) {
      return;
    }
    _pendingNotificationConversation = null;
    navigatorKey.currentState?.pushNamedAndRemoveUntil(
      '/messenger',
      (_) => false,
      arguments: id,
    );
  }

  void _onOnboardingChanged() {
    unawaited(chatFolders.open());
    if (onboarding.status == LoomOnboardingStatus.complete) {
      if (!_hadCompleteSession) {
        _hadCompleteSession = true;
        unawaited(calls.open());
        unawaited(messaging.open().then((_) => groups?.open()));
        unawaited(_drainNotification());
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => unawaited(_drainGroupLink()),
        );
        // Nearby/DTN is a product default. Start it once when a registered
        // session becomes active; a user can still disable it explicitly from
        // Settings for the remainder of that session.
        unawaited(nearbyDtn.enable());
      }
      return;
    }

    if (_hadCompleteSession && onboarding.status == LoomOnboardingStatus.idle) {
      _hadCompleteSession = false;
      unawaited(LoomPlaybackController.closeAll());
      unawaited(nearbyDtn.disable());
      final oldMessaging = messaging;
      final oldCalls = calls;
      _createSessionControllers();
      oldCalls.dispose();
      oldMessaging.dispose();
      if (mounted) {
        setState(() {});
      }
    }
  }

  @override
  void dispose() {
    _groupLinkChannel.setMethodCallHandler(null);
    _themeLerp?.dispose();
    // Notify surviving playback hosts after the locked teardown finishes.
    scheduleMicrotask(() => unawaited(LoomPlaybackController.closeAll()));
    onboarding.removeListener(_onOnboardingChanged);
    _acceptedSendDtnMirror?.dispose();
    _acceptedSendDtnMirror = null;
    nearbyDtn.onLocalInboxChanged = null;
    nearbyDtn.canConfirmLegacyDelivery = null;
    nearbyDtn.dispose();
    chatFolders.dispose();
    _notifications?.dispose();
    groupCalls?.dispose();
    groups?.dispose();
    calls.dispose();
    messaging.dispose();
    onboarding.dispose();
    nodeDirectory.dispose();
    callRouteObserver.activeCallVisible.dispose();
    groupCallRouteObserver.visible.dispose();
    super.dispose();
  }

  static const _systemLocaleCode = 'sys';

  /// The concrete locale rendered by MaterialApp, resolved from the
  /// preference: explicit choices win, otherwise follow the OS (fa→fa,
  /// everything else→en). Recomputed on every build so a mid-session OS
  /// language change is picked up on the next theme pass.
  Locale get _resolvedLocale {
    switch (localePreference) {
      case 'fa':
        return const Locale('fa');
      case 'en':
        return const Locale('en');
    }
    final system = WidgetsBinding.instance.platformDispatcher.locale;
    return system.languageCode == 'fa' ? const Locale('fa') : const Locale('en');
  }

  String? get _localeFontFamily =>
      _resolvedLocale.languageCode == 'fa' ? 'Vazirmatn' : null;

  ThemeData get _theme => switch (mode) {
    LoomThemeMode.light => LoomTheme.light(
      fontFamily: _localeFontFamily,
      accent: accent == null ? null : Color(accent!),
    ),
    LoomThemeMode.dark => LoomTheme.dark(
      fontFamily: _localeFontFamily,
      accent: accent == null ? null : Color(accent!),
    ),
    LoomThemeMode.oled => LoomTheme.oled(
      fontFamily: _localeFontFamily,
      accent: accent == null ? null : Color(accent!),
    ),
  };

  /// The theme actually rendered; eases from the previous theme after a
  /// change, and respects the reduced-motion preference.
  ThemeData get _displayedTheme {
    final lerp = _themeLerp;
    final from = _themeFrom;
    if (lerp == null || from == null) {
      return _theme;
    }
    final eased = Curves.easeOutCubic.transform(lerp.value);
    return ThemeData.lerp(from, _theme, eased);
  }

  void _mutateWithThemeTransition(VoidCallback mutate) {
    // The explicit in-app reduced-motion preference wins; system signals are
    // not readable above MaterialApp, and the settings toggle covers intent.
    final reduceMotion = motion == LoomMotionPreference.reduced;
    final from = _theme;
    setState(mutate);
    if (identical(from, _theme) || reduceMotion) {
      return;
    }
    _themeLerp?.dispose();
    _themeFrom = from;
    _themeLerp =
        AnimationController(vsync: this, duration: LoomMotion.choreography)
          ..addListener(() => setState(() {}))
          ..addStatusListener((status) {
            if (status == AnimationStatus.completed) {
              _themeFrom = null;
            }
          })
          ..forward();
  }

  Widget _settings(LoomSettingsSection section) => LoomSettingsDetailScreen(
    section: section,
    themeMode: mode,
    glassQuality: glassQuality,
    locale: _resolvedLocale,
    localePreference: localePreference,
    onThemeChanged: _setTheme,
    onGlassQualityChanged: _setGlass,
    onLocaleChanged: _setLocale,
  );

  bool _shouldBackgroundSync() =>
      !LoomAppLock.instance.locked &&
      (messaging.status == LoomMessagingSessionStatus.ready ||
          messaging.status == LoomMessagingSessionStatus.offline);

  Future<void> _resumeAfterUnlock() async {
    try {
      final restored = await onboarding.restorePersistedSession();
      if (!restored || !mounted || LoomAppLock.instance.locked) {
        return;
      }
      await messaging.refreshLocalMessages();
      if (!mounted || LoomAppLock.instance.locked) {
        return;
      }
      await calls.resumeAfterUnlock();
      unawaited(groups?.open());
      await _drainNotification();
      unawaited(_drainGroupLink());
    } catch (_) {
      // StartupGate owns the user-visible retry/error state. Keep the existing
      // protected data intact and let its restore attempt surface the code.
    }
  }

  @override
  Widget build(BuildContext context) {
    return LoomNodeDirectoryScope(
      controller: nodeDirectory,
      child: LoomOnboardingScope(
        controller: onboarding,
        child: LoomMessagingSessionScope(
          controller: messaging,
          child: LoomGroupsScope(
            controller: groups!,
            child: LoomGroupCallScope(
              controller: groupCalls!,
              child: LoomCallSessionScope(
                controller: calls,
                child: LoomChatFoldersScope(
                  controller: chatFolders,
                  child: LoomMessagingSyncHeartbeat(
                    shouldSync: _shouldBackgroundSync,
                    synchronize: () async {
                      await messaging.synchronize();
                      if (!LoomAppLock.instance.locked) {
                        await groups?.synchronize();
                      }
                    },
                    child: LoomGlassScope(
                      quality: glassQuality,
                      child: MaterialApp(
                        navigatorKey: navigatorKey,
                        navigatorObservers: <NavigatorObserver>[
                          callRouteObserver,
                          groupCallRouteObserver,
                        ],
                        builder: (context, child) =>
                            AnnotatedRegion<SystemUiOverlayStyle>(
                              value:
                                  (Theme.of(context).brightness ==
                                              Brightness.dark
                                          ? SystemUiOverlayStyle.light
                                          : SystemUiOverlayStyle.dark)
                                      .copyWith(
                                        statusBarColor: Colors.transparent,
                                        systemNavigationBarColor:
                                            Colors.transparent,
                                        systemNavigationBarDividerColor:
                                            Colors.transparent,
                                        systemStatusBarContrastEnforced: false,
                                        systemNavigationBarContrastEnforced:
                                            false,
                                      ),
                              child: LoomAccessibilityScope(
                                overrides: LoomAccessibilityOverrides(
                                  reduceMotion:
                                      motion == LoomMotionPreference.reduced
                                      ? true
                                      : null,
                                ),
                                child: LoomAppearanceScope(
                                  mode: mode,
                                  motion: motion,
                                  chatDensity: chatDensity,
                                  onChatDensityChanged: (value) {
                                    setState(() => chatDensity = value);
                                    _saveAppearance();
                                  },
                                  onMotionChanged: (value) {
                                    setState(() => motion = value);
                                    _saveAppearance();
                                  },
                                  accent: accent,
                                  onAccentChanged: (value) {
                                    _mutateWithThemeTransition(
                                      () => accent = value,
                                    );
                                    _saveAppearance();
                                  },
                                  onChanged: _setTheme,
                                  child: LoomChatLayoutScope(
                                    density: chatDensity,
                                    child: LoomCallOverlayHost(
                                      navigatorKey: navigatorKey,
                                      routeObserver: callRouteObserver,
                                      child: LoomAppLockGate(
                                        onLocked: () {
                                          messaging.clearReadableState();
                                          onboarding.clearTransientSecrets();
                                        },
                                        onUnlocked: () {
                                          unawaited(_resumeAfterUnlock());
                                        },
                                        child: LoomPlaybackHost(
                                          navigatorKey: navigatorKey,
                                          child: LoomGroupCallOverlayHost(
                                            navigatorKey: navigatorKey,
                                            observer: groupCallRouteObserver,
                                            child:
                                                child ??
                                                const SizedBox.shrink(),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        debugShowCheckedModeBanner: false,
                        title: 'Loom',
                        theme: _displayedTheme,
                        locale: _resolvedLocale,
                        localizationsDelegates: const [
                          GlobalMaterialLocalizations.delegate,
                          GlobalWidgetsLocalizations.delegate,
                          GlobalCupertinoLocalizations.delegate,
                        ],
                        supportedLocales: const [Locale('en'), Locale('fa')],
                        initialRoute: '/',
                        routes: <String, WidgetBuilder>{
                          '/': (_) => LoomStartupGate(
                            controller: onboarding,
                            onThemeChanged: _setTheme,
                            onLocaleChanged: _setLocale,
                          ),
                          '/nodes': (_) =>
                              const LoomOnboardingNodeSelectionScreen(),
                          '/node-detail': (_) => const NodeDetailScreen(),
                          '/identity': (_) => const IdentityCreationScreen(),
                          '/restore': (_) => const RestoreIdentityScreen(),
                          '/sign-in': (_) => const LoomSignInScreen(),
                          '/link-device': (_) => const LinkDeviceScreen(),
                          '/recovery': (_) => const RecoveryScreen(),
                          '/recovery-verify': (_) =>
                              const RecoveryVerificationScreen(),
                          '/ready': (_) => const ReadyScreen(),
                          '/messenger': (_) => const MessengerShell(),
                          '/people': (_) => const LoomPeopleScreen(),
                          '/profile': (_) =>
                              const ProfileScreen(preview: false),
                          '/profile-qr': (_) => const LoomProfileQrScreen(),
                          '/security': (_) => const SecurityScreen(),
                          '/calls': (_) => const LoomCallsScreen(),
                          loomActiveCallRouteName: (_) =>
                              const LoomActiveCallRoute(),
                          '/settings/chat-folders': (_) =>
                              const LoomChatFoldersSettingsScreen(),
                          '/settings/privacy': (_) =>
                              _settings(LoomSettingsSection.privacy),
                          '/settings/notifications': (_) =>
                              _settings(LoomSettingsSection.notifications),
                          '/settings/storage': (_) =>
                              _settings(LoomSettingsSection.storage),
                          '/settings/appearance': (_) =>
                              _settings(LoomSettingsSection.appearance),
                          '/settings/nearby': (_) =>
                              LoomNearbyModeScreen(controller: nearbyDtn),
                          '/settings/nearby-diagnostics': (_) =>
                              const LoomNearbyDiagnosticsScreen(),
                          '/settings/federation': (_) =>
                              _settings(LoomSettingsSection.federation),
                          '/settings/calls': (_) =>
                              _settings(LoomSettingsSection.calls),
                          '/settings/language': (_) =>
                              _settings(LoomSettingsSection.language),
                          '/settings/advanced': (_) =>
                              _settings(LoomSettingsSection.advanced),
                          '/settings/about': (_) =>
                              _settings(LoomSettingsSection.about),
                          '/settings/shared-media': (_) =>
                              _settings(LoomSettingsSection.sharedMedia),
                          if (loomDevelopmentSurfacesEnabled)
                            '/design-lab': (_) => DesignLabScreen(
                              themeMode: mode,
                              glassQuality: glassQuality,
                              locale: _resolvedLocale,
                              onThemeChanged: _setTheme,
                              onGlassQualityChanged: _setGlass,
                              onLocaleChanged: _setLocale,
                            ),
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
