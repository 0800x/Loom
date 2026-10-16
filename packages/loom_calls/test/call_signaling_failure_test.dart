import 'dart:async';

import 'package:loom_calls/loom_calls.dart';
import 'package:loom_models/loom_models.dart';
import 'package:loom_protocol/loom_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

class _Api implements LoomCallApi {
  final configuration = Completer<LoomRtcConfiguration>();
  @override
  Future<LoomRtcConfiguration> fetchRtcConfiguration() =>
      configuration.future;
  @override
  Future<List<LoomPendingCall>> fetchPendingCalls() async => [];
}

class _Signaling implements LoomCallSignalingConnection {
  final events = StreamController<LoomCallSignal>.broadcast(sync: true);
  final sent = <LoomCallSignal>[];
  @override
  Stream<LoomCallSignal> get signals => events.stream;
  @override
  Future<void> connect() async {}
  @override
  Future<void> send(LoomCallSignal signal) async {
    sent.add(signal);
  }

  @override
  Future<void> dispose() => events.close();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

LoomRtcConfiguration _configuration() => LoomRtcConfiguration(
      iceServers: const [],
      expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 5)),
    );

void main() {
  test(
    'a server rejection survives a late RTC config and never starts native media',
    () async {
      final api = _Api();
      final signaling = _Signaling();
      final engine = LoomCallEngine(
        api: api,
        signaling: signaling,
        localIdentityId: 'self',
      );
      addTearDown(engine.dispose);
      await engine.initialize();
      final start = engine.startOutgoing(
        conversationId: 'conv',
        peerIdentityId: 'peer',
        kind: LoomCallKind.audio,
      );
      final callId = engine.state.callId!;
      final rejection = LoomCallSignalingException(
        callId,
        'call_conversation_not_found',
      );
      final result = expectLater(start, throwsA(same(rejection)));
      signaling.events.addError(rejection);
      expect(engine.state.lifecycle, LoomCallLifecycle.failed);
      expect(engine.state.endReason, LoomCallEndReason.signalingFailure);
      api.configuration.complete(_configuration());
      await result;
      expect(engine.state.error, same(rejection));
      expect(engine.state.lifecycle, LoomCallLifecycle.failed);
      expect(engine.state.reconnectAttempts, 0);
      expect(signaling.sent.where((s) => s.kind == 'call.offer'), isEmpty);
    },
  );

  test('an error for another call cannot end the current attempt', () async {
    final api = _Api();
    final signaling = _Signaling();
    final engine = LoomCallEngine(
      api: api,
      signaling: signaling,
      localIdentityId: 'self',
    );
    addTearDown(engine.dispose);
    await engine.initialize();
    final start = engine.startOutgoing(
      conversationId: 'conv',
      peerIdentityId: 'peer',
      kind: LoomCallKind.audio,
    );
    final result = expectLater(start, throwsA(isA<LoomProtocolException>()));
    signaling.events.addError(
      const LoomCallSignalingException('old-call', 'call_signaling_failed'),
    );
    expect(engine.state.lifecycle, LoomCallLifecycle.preparing);
    expect(engine.state.error, isNull);
    api.configuration.completeError(
      const LoomProtocolException('RTC configuration unavailable'),
    );
    await result;
  });

  test(
    'hangup during setup cannot resume media after config arrives',
    () async {
      final api = _Api();
      final signaling = _Signaling();
      final engine = LoomCallEngine(
        api: api,
        signaling: signaling,
        localIdentityId: 'self',
      );
      addTearDown(engine.dispose);
      await engine.initialize();
      final start = engine.startOutgoing(
        conversationId: 'conv',
        peerIdentityId: 'peer',
        kind: LoomCallKind.video,
      );
      final result = expectLater(start, throwsStateError);
      await engine.hangUp();
      api.configuration.complete(_configuration());
      await result;
      expect(engine.state.lifecycle, LoomCallLifecycle.ended);
      expect(engine.state.endReason, LoomCallEndReason.localHangup);
      expect(signaling.sent.where((s) => s.kind == 'call.offer'), isEmpty);
    },
  );
  test('remote hangup during preparation is handled before a peer exists',
      () async {
    final api = _Api();
    final signaling = _Signaling();
    final engine = LoomCallEngine(
        api: api, signaling: signaling, localIdentityId: 'self');
    addTearDown(engine.dispose);
    await engine.initialize();
    final start = engine.startOutgoing(
        conversationId: 'conv',
        peerIdentityId: 'peer',
        kind: LoomCallKind.audio);
    final result = expectLater(start, throwsStateError);
    signaling.events.add(LoomCallSignal(
        callId: engine.state.callId!,
        conversationId: 'conv',
        senderIdentityId: 'peer',
        targetIdentityId: 'self',
        kind: 'call.end',
        sequence: 1,
        createdAt: DateTime.now().toUtc(),
        reason: 'localHangup'));
    expect(engine.state.lifecycle, LoomCallLifecycle.ended);
    api.configuration.complete(_configuration());
    await result;
    expect(engine.state.endReason, LoomCallEndReason.remoteHangup);
    expect(signaling.sent.where((s) => s.kind == 'call.offer'), isEmpty);
  });
}
