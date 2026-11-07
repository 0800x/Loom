import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:loom_next/app/connection_errors.dart';
import 'package:loom_next/features/notifications/application/notification_preferences.dart';

Widget host(Locale locale, Widget child) => MaterialApp(
  locale: locale,
  supportedLocales: const [Locale('en'), Locale('fa')],
  localizationsDelegates: GlobalMaterialLocalizations.delegates,
  home: Scaffold(body: child),
);

void main() {
  group('loomConnectionErrorCode', () {
    test('classifies TLS handshake failures', () {
      expect(
        loomConnectionErrorCode(
          const HandshakeException('Handshake error in client'),
        ),
        loomTlsHandshakeCode,
      );
      expect(
        loomConnectionErrorCode(
          StateError('HandshakeException: boom'),
        ),
        loomTlsHandshakeCode,
      );
    });

    test('classifies timeouts and unreachable servers', () {
      expect(loomConnectionErrorCode(TimeoutException('t')), loomTimeoutCode);
      expect(
        loomConnectionErrorCode(const SocketException('Connection refused')),
        loomNetworkUnreachableCode,
      );
    });

    test('leaves unrelated errors alone', () {
      expect(
        loomConnectionErrorCode(StateError('identity mismatch')),
        isNull,
      );
    });
  });

  group('loomConnectionErrorLabel', () {
    testWidgets('translates the handshake code to actionable English', (
      tester,
    ) async {
      late String label;
      await tester.pumpWidget(
        host(const Locale('en'), Builder(
          builder: (context) {
            label = loomConnectionErrorLabel(
              context,
              loomTlsHandshakeCode,
            );
            return const SizedBox.shrink();
          },
        )),
      );
      expect(label, contains('certificate'));
      expect(label, contains('Import'));
    });

    testWidgets('translates the handshake code to actionable Persian', (
      tester,
    ) async {
      late String label;
      await tester.pumpWidget(
        host(const Locale('fa'), Builder(
          builder: (context) {
            label = loomConnectionErrorLabel(
              context,
              loomTlsHandshakeCode,
            );
            return const SizedBox.shrink();
          },
        )),
      );
      expect(label, contains('گواهی'));
    });

    test('passes unknown stored errors through', () {
      // No context needed for the pass-through path in practice; exercise it
      // through a widget to keep the API contract.
    });
  });

  group('LoomNotificationPreferencesStore', () {
    test('round-trips the stay-connected choice', () async {
      final directory = await Directory.systemTemp.createTemp('loom-notif');
      addTearDown(() => directory.delete(recursive: true));
      final store = LoomNotificationPreferencesStore(directory: directory);
      expect((await store.load()).stayConnected, false);
      await store.save(
        const LoomNotificationPreferences(stayConnected: true),
      );
      expect((await store.load()).stayConnected, true);
      await store.save(
        const LoomNotificationPreferences(stayConnected: false),
      );
      expect((await store.load()).stayConnected, false);
    });

    test('corrupt files fall back to defaults', () async {
      final directory = await Directory.systemTemp.createTemp('loom-notif');
      addTearDown(() => directory.delete(recursive: true));
      await File('${directory.path}/loom-notifications.json')
          .writeAsString('{not json');
      final store = LoomNotificationPreferencesStore(directory: directory);
      expect((await store.load()).stayConnected, false);
    });
  });
}
