import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { LoomFederatedCallGateway, CALL_FEDERATION_PROTOCOL, type FederatedCallSignal } from '../src/calls/federated_call_signal.ts';
import { LoomNodeIdentity } from '../src/identity/node_identity.ts';

for (const mediaKind of ['audio', 'video'] as const) {
  test(`signed federated ${mediaKind} offer preserves multiline SDP and rejects tampering`, async () => {
    const dir = mkdtempSync(join(tmpdir(), 'loom-call-federation-'));
    try {
      const origin = LoomNodeIdentity.loadOrCreate(join(dir, 'origin'));
      const destination = LoomNodeIdentity.loadOrCreate(join(dir, 'destination'));
      const refreshed: boolean[] = [];
      const gateway = new LoomFederatedCallGateway(
        { publicDomain: 'receiver.example', federationMode: 'trusted' } as never,
        destination,
        {
          discover: async () => ({ ...origin.publicInfo(), domain: 'sender.example',
            endpoint: 'https://sender.example', trustState: 'trusted' }),
          resolveUser: async (address: string, force: boolean) => {
            assert.equal(address, '@alice:sender.example');
            refreshed.push(force);
            return { identity: { identityId: 'chn:alice' } };
          },
        } as never,
      );
      const sdp = `v=0\r\ns=-\r\nt=0 0\r\nm=${mediaKind} 9 UDP/TLS/RTP/SAVPF 111\r\n`;
      const unsigned = {
        protocol: CALL_FEDERATION_PROTOCOL,
        eventId: 'fcallsig_00000000-0000-4000-8000-000000000001',
        originNodeId: origin.publicInfo().nodeId,
        originDomain: 'sender.example',
        destinationNodeId: destination.publicInfo().nodeId,
        destinationDomain: 'receiver.example',
        senderAddress: '@alice:sender.example', recipientAddress: '@bob:receiver.example',
        senderIdentityId: 'chn:alice', targetIdentityId: 'chn:bob', senderDisplayName: 'Alice',
        callId: 'call-real-sdp', conversationId: 'conv-bob', kind: 'call.offer', sequence: 1,
        createdAt: new Date().toISOString(), mediaKind, sdp, sdpType: 'offer',
      };
      // This envelope contains only scalar fields; sorting signs the exact wire
      // values, including every CR/LF, rather than a normalized SDP document.
      const sign = (value: typeof unsigned): FederatedCallSignal => ({ ...value,
        signature: origin.signUtf8(JSON.stringify(Object.fromEntries(
          Object.entries(value).sort(([a], [b]) => a.localeCompare(b)),
        ))),
      });
      const envelope = sign(unsigned);
      assert.equal((await gateway.verifyInbound(envelope)).sdp, sdp);
      await assert.rejects(gateway.verifyInbound({ ...envelope, sdp: sdp.replaceAll('\r\n', '\n') }), /invalid_call_federation_signature/);
      await assert.rejects(gateway.verifyInbound({ ...envelope, targetIdentityId: 'chn:mallory' }), /invalid_call_federation_signature/);
      const answer = sign({ ...unsigned, kind: 'call.answer', sequence: 2, sdpType: 'answer' });
      assert.equal((await gateway.verifyInbound(answer)).sdp, sdp);
      assert.deepEqual(refreshed, [true, false]);
    } finally { rmSync(dir, { recursive: true, force: true }); }
  });
}
