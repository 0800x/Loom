import assert from 'node:assert/strict';
import test from 'node:test';
import { EventEmitter } from 'node:events';

import { LoomCallRealtimeService } from '../src/calls/call_realtime_service.ts';
import type { LoomNodeConfig } from '../src/config/config.ts';
import type { SessionInfo } from '../src/storage/sqlite_store.ts';

const config: LoomNodeConfig = {
  schemaVersion: 1,
  mode: 'easy',
  listenHost: '127.0.0.1',
  listenPort: 7483,
  publicDomain: 'localhost:7483',
  publicBaseUrl: 'http://localhost:7483',
  dataDirectory: '/tmp/loom-call-test',
  attachmentsDirectory: '/tmp/loom-call-test/attachments',
  registrationPolicy: 'open',
  federationMode: 'disabled',
  networkJurisdiction: 'test',
  operatorName: 'test',
  adminToken: 'x'.repeat(32),
  maxAttachmentBytes: 1024 * 1024,
  maxRequestBytes: 1024 * 1024,
  callsEnabled: true,
};

const session: SessionInfo = {
  accountId: 'acc_alice',
  deviceId: 'dev_00000000-0000-0000-0000-000000000001',
  username: 'alice',
  identityId: 'chn:alice',
};

function fixture() {
  const sent: string[] = [];
  const federation = {
    resolveUser: async (address: string, _force = false) => ({
      address,
      displayName: 'Bob',
      identity: {
        identityId: address.startsWith('@bob:') ? 'chn:bob' : 'chn:alice',
        publicKey: 'unused',
        fingerprint: 'unused',
      },
      homeNode: { nodeId: 'node-local', domain: 'localhost:7483' },
      version: '1',
      updatedAt: new Date().toISOString(),
    }),
    routing: {
      resolveLocalUser: async (username = 'alice') => ({
        address: `@${username}:localhost:7483`,
        displayName: username,
        identity: {
          identityId: `chn:${username}`,
          publicKey: 'unused',
          fingerprint: 'unused',
        },
        homeNode: { nodeId: 'node-local', domain: 'localhost:7483' },
        version: '1',
        updatedAt: new Date().toISOString(),
      }),
      ensureRemoteConversation: async () => 'conv-bob',
    },
  };
  const federatedCalls = {
    send: async (): Promise<void> => {
      throw new Error('federation must not be used for same-node test');
    },
  };
  const push = {
    available: false,
    wakeIncomingCall: async () => undefined,
  };
  const service = new LoomCallRealtimeService(
    config,
    federation as never,
    federatedCalls as never,
    push as never,
    async (accountId) => [
      {
        id: 'conv-bob',
        kind: 'direct',
        peerAddress: accountId === 'acc_bob' ? '@alice:localhost:7483' : '@bob:localhost:7483',
      },
    ],
  );
  const connection = {
    session,
    connectedAt: Date.now(),
    alive: true,
    socket: {
      readyState: 1,
      send: (value: string) => sent.push(value),
    },
  };
  return { service, connection, sent, federation, federatedCalls };
}

test('malformed call signaling is ignored without routing or leaking details', async () => {
  const { service, connection, sent } = fixture();
  try {
    await (service as any).handleClientFrame(connection, '{ definitely not json');
    await (service as any).handleClientFrame(
      connection,
      JSON.stringify({
        kind: 'call.offer',
        callId: 'call-1',
        conversationId: 'conv-bob',
        targetIdentityId: 'chn:bob',
        sequence: -1,
      }),
    );
    const diagnostics = service.diagnostics() as Record<string, number>;
    assert.equal(diagnostics.malformedFrames, 2);
    assert.equal(diagnostics.routedSignals, 0);
    assert.deepEqual(sent, []);
  } finally {
    service.close();
  }
});

test('duplicate sender/call/sequence signaling is processed once', async () => {
  const { service, connection, sent } = fixture();
  const frame = JSON.stringify({
    kind: 'call.end',
    callId: 'call-duplicate',
    conversationId: 'conv-bob',
    targetIdentityId: 'chn:bob',
    sequence: 9,
    reason: 'localHangup',
  });
  try {
    await (service as any).handleClientFrame(connection, frame);
    await (service as any).handleClientFrame(connection, frame);
    const diagnostics = service.diagnostics() as Record<string, number>;
    assert.equal(diagnostics.routedSignals, 1);
    assert.equal(diagnostics.malformedFrames, 0);
    assert.deepEqual(sent, []);
  } finally {
    service.close();
  }
});

test('client cannot spoof a target identity for the conversation', async () => {
  const { service, connection, sent } = fixture();
  try {
    await (service as any).handleClientFrame(
      connection,
      JSON.stringify({
        kind: 'call.end',
        callId: 'call-spoof',
        conversationId: 'conv-bob',
        targetIdentityId: 'chn:not-bob',
        sequence: 1,
      }),
    );
    const diagnostics = service.diagnostics() as Record<string, number>;
    assert.equal(diagnostics.routedSignals, 0);
    assert.equal(sent.length, 1);
    const error = JSON.parse(sent[0]) as Record<string, unknown>;
    assert.equal(error.kind, 'call.error');
    assert.equal(error.callId, 'call-spoof');
    assert.equal(error.conversationId, 'conv-bob');
    assert.equal(error.reason, 'call_target_identity_mismatch');
    assert.equal('sdp' in error, false);
    assert.equal('candidate' in error, false);
  } finally {
    service.close();
  }
});


test('a missing conversation returns a rejection scoped to the same call', async () => {
  const { service, connection, sent } = fixture();
  try {
    await (service as any).handleClientFrame(connection, JSON.stringify({
      kind: 'call.offer', callId: 'call-unsynced', conversationId: 'local-only-conversation',
      targetIdentityId: 'chn:bob', sequence: 1, mediaKind: 'audio',
      sdp: 'v=0', sdpType: 'offer',
    }));
    assert.equal(sent.length, 1);
    const error = JSON.parse(sent[0]);
    assert.equal(error.kind, 'call.error');
    assert.equal(error.callId, 'call-unsynced');
    assert.equal(error.reason, 'call_conversation_not_found');
    assert.equal('sdp' in error, false);
    assert.equal((service.diagnostics() as Record<string, number>).routedSignals, 0);
  } finally {
    service.close();
  }
});

// Real WebRTC descriptions contain CRLF throughout. Single-line 'v=0'
// fixtures did not catch the old identifier validator rejecting every offer.
for (const mediaKind of ['audio', 'video'] as const) {
  for (const newline of ['\r\n', '\n']) {
    test(`${mediaKind} multiline offer reaches the receiver and REST recovery (${JSON.stringify(newline)})`, async () => {
      const { service, connection, sent } = fixture();
      const received: string[] = [];
      const socket = Object.assign(new EventEmitter(), {
        readyState: 1,
        send: (frame: string) => received.push(frame),
        close() { this.emit('close'); },
      });
      const recipient = { ...session, accountId: 'acc_bob', username: 'bob', identityId: 'chn:bob' };
      service.attach(recipient, socket as never);
      const sdp = ['v=0', 'o=- 1234 2 IN IP4 127.0.0.1', 's=-', 't=0 0',
        `m=${mediaKind} 9 UDP/TLS/RTP/SAVPF 111`, 'a=ice-ufrag:abc', 'a=ice-pwd:long-enough-test-password', ''].join(newline);
      try {
        await (service as any).handleClientFrame(connection, JSON.stringify({
          kind: 'call.offer', callId: 'call-real-sdp', conversationId: 'conv-bob',
          targetIdentityId: 'chn:bob', sequence: 1, mediaKind, sdp, sdpType: 'offer',
        }));
        assert.equal(received.length, 1);
        assert.equal(JSON.parse(received[0]).sdp, sdp);
        assert.equal(JSON.parse(received[0]).mediaKind, mediaKind);
        const pending = await service.pendingFor(recipient);
        assert.equal(pending.length, 1);
        assert.equal(pending[0].offerSdp, sdp);
        assert.equal(pending[0].kind, mediaKind);
        await (service as any).handleClientFrame(connection, JSON.stringify({
          kind: 'call.answer', callId: 'call-real-sdp', conversationId: 'conv-bob',
          targetIdentityId: 'chn:bob', sequence: 2, sdp, sdpType: 'answer',
        }));
        assert.equal(JSON.parse(received[1]).sdp, sdp);
        // A caller's answer is not evidence that the callee answered.
        assert.equal((await service.pendingFor(recipient)).length, 1);
        await (service as any).handleClientFrame({ ...connection, session: recipient }, JSON.stringify({
          kind: 'call.answer', callId: 'call-real-sdp', conversationId: 'conv-bob',
          targetIdentityId: 'chn:alice', sequence: 1, sdp, sdpType: 'answer',
        }));
        assert.deepEqual(await service.pendingFor(recipient), []);
        assert.equal(service.diagnostics().malformedFrames, 0);
        assert.deepEqual(sent, []);
      } finally { service.close(); }
    });
  }
}

test('SDP relaxation does not allow multiline identities, control bytes or oversized documents', async () => {
  const { service, connection } = fixture();
  const base = {kind: 'call.offer', callId: 'valid-call', conversationId: 'conv-bob',
    targetIdentityId: 'chn:bob', sequence: 1, mediaKind: 'audio', sdpType: 'offer', sdp: 'v=0\r\ns=-\r\n'};
  try {
    for (const change of [{callId:'bad\ncall'}, {targetIdentityId:'chn:bob\nspoof'},
      {sdp:'v=0\0'}, {sdp:'x'.repeat(512 * 1024 + 1)}, {sdp:42}]) {
      await (service as any).handleClientFrame(connection, JSON.stringify({...base,...change}));
    }
    assert.equal(service.diagnostics().malformedFrames, 5);
    assert.equal(service.diagnostics().routedSignals, 0);
  } finally { service.close(); }
});

test('ICE and hangup cannot overtake an offer awaiting profile resolution', { timeout: 2_000 }, async () => {
  const { service, federation } = fixture();
  const received: Array<Record<string, unknown>> = [];
  const refreshed: boolean[] = [];
  let release!: () => void;
  let started!: () => void;
  let completed!: () => void;
  const blocked = new Promise<void>((resolve) => { release = resolve; });
  const resolving = new Promise<void>((resolve) => { started = resolve; });
  const done = new Promise<void>((resolve) => { completed = resolve; });
  const resolveUser = federation.resolveUser;
  federation.resolveUser = async (address, force = false) => {
    refreshed.push(force);
    if (force) { started(); await blocked; }
    return resolveUser(address, force);
  };
  const sender = Object.assign(new EventEmitter(), {
    readyState: 1,
    send: () => assert.fail('valid signaling must not produce an error'),
    close() { this.emit('close'); },
  });
  const receiver = Object.assign(new EventEmitter(), {
    readyState: 1,
    send: (frame: string) => {
      received.push(JSON.parse(frame));
      if (received.length === 3) completed();
    },
    close() { this.emit('close'); },
  });
  service.attach(session, sender as never);
  const recipient = { ...session, accountId: 'acc_bob', username: 'bob', identityId: 'chn:bob' };
  service.attach(recipient, receiver as never);
  const base = { callId: 'ordered-call', conversationId: 'conv-bob', targetIdentityId: 'chn:bob' };
  try {
    sender.emit('message', JSON.stringify({ ...base, kind: 'call.offer', sequence: 1,
      mediaKind: 'video', sdp: 'v=0\r\ns=-\r\n', sdpType: 'offer' }), false);
    await resolving;
    sender.emit('message', JSON.stringify({ ...base, kind: 'call.ice', sequence: 2,
      candidate: 'candidate:1 1 udp 1 192.0.2.1 5000 typ host', sdpMid: '0', sdpMLineIndex: 0 }), false);
    sender.emit('message', JSON.stringify({ ...base, kind: 'call.end', sequence: 3 }), false);
    await new Promise((resolve) => setImmediate(resolve));
    assert.deepEqual(received, []);
    assert.deepEqual(refreshed, [true]);
    release();
    await done;
    assert.deepEqual(received.map((frame) => frame.kind), ['call.offer', 'call.ice', 'call.end']);
    assert.deepEqual(refreshed, [true, false, false]);
    assert.deepEqual(await service.pendingFor(recipient), []);
  } finally { release(); service.close(); }
});

test('an overfilled signaling queue closes instead of retaining unbounded frames', async () => {
  const { service } = fixture();
  const closed: number[] = [];
  const socket = Object.assign(new EventEmitter(), {
    readyState: 1, send: () => undefined,
    close(code: number) { closed.push(code); this.readyState = 3; this.emit('close'); },
  });
  service.attach(session, socket as never);
  try {
    for (let sequence = 0; sequence < 300; sequence++) {
      socket.emit('message', JSON.stringify({ kind: 'call.end', callId: 'queued-call',
        conversationId: 'conv-bob', targetIdentityId: 'chn:bob', sequence }), false);
    }
    await new Promise((resolve) => setImmediate(resolve));
    assert.deepEqual(closed, [1013]);
    assert.equal(service.diagnostics().routedSignals, 0);
  } finally { service.close(); }
});

const bobSession = { ...session, accountId: 'acc_bob', username: 'bob', identityId: 'chn:bob' };

function receiverSocket(frames: Array<Record<string, unknown>>) {
  return Object.assign(new EventEmitter(), {
    readyState: 1,
    send(frame: string) { frames.push(JSON.parse(frame)); },
    close() { this.readyState = 3; this.emit('close'); },
  });
}

async function pendingOffer(service: LoomCallRealtimeService, connection: unknown, kind: 'audio' | 'video') {
  await (service as any).handleClientFrame(connection, JSON.stringify({
    kind: 'call.offer', callId: 'reconnect-call', conversationId: 'conv-bob', targetIdentityId: 'chn:bob',
    sequence: 1, mediaKind: kind, sdp: 'v=0\r\ns=-\r\n', sdpType: 'offer',
  }));
  await (service as any).handleClientFrame(connection, JSON.stringify({
    kind: 'call.ice', callId: 'reconnect-call', conversationId: 'conv-bob', targetIdentityId: 'chn:bob',
    sequence: 2, candidate: 'candidate:1 1 udp 1 192.0.2.1 5000 typ host', sdpMid: '0', sdpMLineIndex: 0,
  }));
}

for (const kind of ['audio', 'video'] as const) {
  test(`${kind} incoming offer and early ICE replay immediately on receiver reconnect`, async () => {
    const { service, connection } = fixture();
    const frames: Array<Record<string, unknown>> = [];
    try {
      await pendingOffer(service, connection, kind);
      service.attach(bobSession, receiverSocket(frames) as never);
      await new Promise((resolve) => setImmediate(resolve));
      assert.deepEqual(frames.map((frame) => frame.kind), ['call.offer', 'call.ice']);
      assert.equal(frames[0].mediaKind, kind);
      assert.ok(frames.every((frame) => frame.conversationId === 'conv-bob' && frame.targetIdentityId === 'chn:bob'));
      assert.equal(frames[0].ice, undefined, 'internal replay buffer must not leak into the wire envelope');
    } finally { service.close(); }
  });
}

test('pending calls never replay to a different authenticated identity', async () => {
  const { service, connection } = fixture();
  const frames: Array<Record<string, unknown>> = [];
  try {
    await pendingOffer(service, connection, 'audio');
    service.attach({ ...bobSession, identityId: 'chn:someone-else' }, receiverSocket(frames) as never);
    await new Promise((resolve) => setImmediate(resolve));
    assert.deepEqual(frames, []);
  } finally { service.close(); }
});

test('hangup during receiver replay lookup does not resurrect an expired ring', async () => {
  const { service, connection, federation } = fixture();
  const frames: Array<Record<string, unknown>> = [];
  let release!: () => void;
  let entered!: () => void;
  const blocked = new Promise<void>((resolve) => { release = resolve; });
  const started = new Promise<void>((resolve) => { entered = resolve; });
  try {
    await pendingOffer(service, connection, 'video');
    federation.routing.ensureRemoteConversation = async () => { entered(); await blocked; return 'conv-bob'; };
    service.attach(bobSession, receiverSocket(frames) as never);
    await started;
    const ended = (service as any).handleClientFrame(connection, JSON.stringify({
      kind: 'call.end', callId: 'reconnect-call', conversationId: 'conv-bob', targetIdentityId: 'chn:bob', sequence: 3,
    }));
    // Let the hangup clear pending while delivery waits behind replay.
    await new Promise((resolve) => setImmediate(resolve));
    release();
    await ended;
    assert.deepEqual(frames.map((frame) => frame.kind), ['call.end']);
    assert.deepEqual(await service.pendingFor(bobSession), []);
  } finally { release(); service.close(); }
});

test('a callee answer routed to another Node clears local pending recovery', async () => {
  const { service, connection, federatedCalls } = fixture();
  try {
    await pendingOffer(service, connection, 'audio');
    const pending = (service as any).pending.get('reconnect-call');
    pending.senderAddress = '@alice:remote.example';
    (service as any).listConversations = async () => [{ id: 'conv-bob', kind: 'direct', peerAddress: '@alice:remote.example' }];
    let forwarded = 0;
    federatedCalls.send = async () => { forwarded++; };
    await (service as any).handleClientFrame({ ...connection, session: bobSession }, JSON.stringify({
      kind: 'call.answer', callId: 'reconnect-call', conversationId: 'conv-bob', targetIdentityId: 'chn:alice',
      sequence: 1, sdp: 'v=0\r\ns=-\r\n', sdpType: 'answer',
    }));
    assert.equal(forwarded, 1);
    assert.deepEqual(await service.pendingFor(bobSession), []);
  } finally { service.close(); }
});
