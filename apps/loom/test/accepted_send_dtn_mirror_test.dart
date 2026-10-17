import 'dart:async';

import 'package:loom_models/loom_models.dart';
import 'package:loom_next/features/messaging/application/accepted_send_dtn_mirror.dart';
import 'package:loom_next/features/nodes/application/node_directory_controller.dart';
import 'package:loom_next/features/onboarding/application/onboarding_controller.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'accepted online send is mirrored once with the same client id',
    () async {
      final harness = _Harness();
      addTearDown(harness.dispose);
      harness.messages = <LoomMessageRecord>[
        harness.message(LoomDeliveryState.sent),
      ];

      final mirrored = Completer<void>();
      var writes = 0;
      String? mirroredClientId;
      String? mirroredCiphertext;
      final mirror = LoomAcceptedSendDtnMirror(
        onboarding: harness.onboarding,
        messagingListenable: harness.changes,
        conversationsProvider: () => <LoomConversation>[harness.conversation],
        messagesProvider: (_) => harness.messages,
        routeResolver: (_) async => harness.route,
        dtnWriter: ({
          required destinationNodeDomain,
          required senderAddress,
          required recipientDevices,
          required conversationId,
          required clientId,
          required type,
          required ciphertext,
          required protocolVersion,
          replyToMessageId,
          createdAt,
          required metadata,
        }) async {
          writes++;
          mirroredClientId = clientId;
          mirroredCiphertext = ciphertext;
          if (!mirrored.isCompleted) mirrored.complete();
        },
        clock: () => harness.now,
      );
      addTearDown(mirror.dispose);

      await mirrored.future.timeout(const Duration(seconds: 1));
      expect(writes, 1);
      expect(mirroredClientId, 'client-accepted-1');
      expect(mirroredCiphertext, 'ciphertext-accepted-1');

      harness.changes.notifyListeners();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        writes,
        1,
        reason: 'the same accepted send must not be mirrored twice',
      );
    },
  );

  test(
    'queued send is not mirrored before authoritative online acceptance',
    () async {
      final harness = _Harness();
      addTearDown(harness.dispose);
      harness.messages = <LoomMessageRecord>[
        harness.message(LoomDeliveryState.queued),
      ];

      final mirrored = Completer<void>();
      var writes = 0;
      final mirror = LoomAcceptedSendDtnMirror(
        onboarding: harness.onboarding,
        messagingListenable: harness.changes,
        conversationsProvider: () => <LoomConversation>[harness.conversation],
        messagesProvider: (_) => harness.messages,
        routeResolver: (_) async => harness.route,
        dtnWriter: ({
          required destinationNodeDomain,
          required senderAddress,
          required recipientDevices,
          required conversationId,
          required clientId,
          required type,
          required ciphertext,
          required protocolVersion,
          replyToMessageId,
          createdAt,
          required metadata,
        }) async {
          writes++;
          if (!mirrored.isCompleted) mirrored.complete();
        },
        clock: () => harness.now,
      );
      addTearDown(mirror.dispose);

      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        writes,
        0,
        reason: 'queued/sending work must use bounded fallback',
      );

      harness.messages = <LoomMessageRecord>[
        harness.message(LoomDeliveryState.sent),
      ];
      harness.changes.notifyListeners();
      await mirrored.future.timeout(const Duration(seconds: 1));
      expect(writes, 1);
    },
  );
}

final class _Harness {
  _Harness() {
    onboarding.committedIdentity = LoomIdentityPublic(
      identityId: 'identity-mirror-test',
      publicKey: 'identity-public-key',
      fingerprint: 'identity-fingerprint',
      createdAt: now.subtract(const Duration(days: 1)),
    );
    onboarding.receipt = const LoomRegistrationReceipt(
      accountId: 'account-mirror-test',
      deviceId: 'device-sender-test',
      address: 'sender@example.test',
      homeNode: 'example.test',
    );
  }

  final DateTime now = DateTime.utc(2026, 9, 15, 12);
  final ChangeNotifier changes = ChangeNotifier();
  final LoomNodeDirectoryController nodes = LoomNodeDirectoryController();
  late final LoomOnboardingController onboarding = LoomOnboardingController(
    nodes: nodes,
  );
  List<LoomMessageRecord> messages = const <LoomMessageRecord>[];

  final LoomConversation conversation = const LoomConversation(
    id: 'conversation-mirror-test',
    kind: LoomConversationKind.direct,
    title: 'Recipient',
    peerAddress: 'recipient@example.test',
    updatedOrder: 1,
    unreadCount: 0,
    isMuted: false,
    isPinned: false,
  );

  final LoomAcceptedSendRoute route = LoomAcceptedSendRoute(
    destinationNodeDomain: 'example.test',
    recipientDevices: <LoomDeviceKeyBundle>[
      LoomDeviceKeyBundle.unsigned(
        identityId: 'identity-recipient-test',
        deviceId: 'device-recipient-test',
        deviceName: 'Recipient phone',
        signingPublicKey: 'signing-key',
        agreementPublicKey: 'agreement-key',
        createdAt: DateTime.utc(2026, 9, 14),
        capabilities: const <String>['messaging'],
      ),
    ],
  );

  LoomMessageRecord message(LoomDeliveryState state) => LoomMessageRecord(
    id: 'message-accepted-1',
    clientId: 'client-accepted-1',
    conversationId: conversation.id,
    senderAddress: 'sender@example.test',
    type: LoomMessageType.text,
    ciphertext: 'ciphertext-accepted-1',
    protocolVersion: 'direct-v1',
    createdOrder: 1,
    createdAt: now,
    deliveryState: state,
  );

  void dispose() {
    changes.dispose();
    onboarding.dispose();
    nodes.dispose();
  }
}
