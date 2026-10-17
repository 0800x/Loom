import test from 'node:test';
import { DatabaseSync } from 'node:sqlite';
import assert from 'node:assert/strict';
import { createHash, generateKeyPairSync, randomBytes, sign } from 'node:crypto';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { WebSocket } from 'ws';
import { LoomNodeServer } from '../src/bootstrap/server.ts';
import type { LoomNodeConfig } from '../src/config/config.ts';
import { canonicalDeviceRequestProof, sha256Hex } from '../src/security/device_request_proof.ts';

const adminToken = 'test-admin-token-012345678901234567890123456789';

function config(dir: string, registrationPolicy: 'open' | 'approval' | 'closed' = 'open'): LoomNodeConfig {
  return {
    schemaVersion: 1,
    mode: 'easy',
    listenHost: '127.0.0.1',
    listenPort: 0,
    publicDomain: 'localhost',
    publicBaseUrl: 'http://localhost',
    dataDirectory: dir,
    attachmentsDirectory: join(dir, 'attachments'),
    registrationPolicy,
    federationMode: 'disabled',
    networkJurisdiction: 'Test',
    operatorName: 'Test Node',
    adminToken,
    maxAttachmentBytes: 1024 * 1024,
    maxRequestBytes: 1024 * 1024,
  };
}

function rawPublicKey(pair: ReturnType<typeof generateKeyPairSync>): Buffer {
  const der = pair.publicKey.export({ type: 'spki', format: 'der' });
  return der.subarray(-32);
}

function fingerprint(bytes: Buffer): string {
  const hex = createHash('sha256').update(bytes).digest('hex').toUpperCase();
  return hex.match(/.{1,4}/g)!.join(' ');
}

function identityMaterial() {
  const pair = generateKeyPairSync('ed25519');
  const raw = rawPublicKey(pair);
  const digest = createHash('sha256').update(raw).digest();
  return {
    pair,
    public: {
      identityId: `chn:${digest.toString('base64url')}`,
      publicKey: raw.toString('base64'),
      fingerprint: fingerprint(raw),
    },
  };
}

function registrationBody(username: string, identity: ReturnType<typeof identityMaterial>): Record<string, unknown> {
  return {
    username,
    displayName: `Display ${username}`,
    password: 'correct horse battery staple',
    deviceName: 'Tests',
    identity: identity.public,
    protocolVersion: 'Loom-Identity-v1',
  };
}

function canonicalBundle(input: {
  identityId: string;
  deviceId: string;
  deviceName: string;
  signingPublicKey: string;
  agreementPublicKey: string;
  createdAt: string;
  capabilities: string[];
}): Buffer {
  return Buffer.from(JSON.stringify({
    bundleVersion: 1,
    identityId: input.identityId,
    deviceId: input.deviceId,
    deviceName: input.deviceName,
    signingPublicKey: input.signingPublicKey,
    agreementPublicKey: input.agreementPublicKey,
    createdAt: input.createdAt,
    capabilities: [...input.capabilities].sort(),
  }), 'utf8');
}

function deviceMaterial(identity: ReturnType<typeof identityMaterial>, deviceId: string) {
  const signingPair = generateKeyPairSync('ed25519');
  const agreementPair = generateKeyPairSync('x25519');
  const unsigned = {
    identityId: identity.public.identityId,
    deviceId,
    deviceName: 'Test Device',
    signingPublicKey: rawPublicKey(signingPair).toString('base64'),
    agreementPublicKey: rawPublicKey(agreementPair).toString('base64'),
    createdAt: new Date().toISOString(),
    capabilities: ['agreement-x25519', 'signing-ed25519'],
  };
  const canonical = canonicalBundle(unsigned);
  return {
    signingPair,
    bundle: {
      ...unsigned,
      bundleVersion: 1 as const,
      fingerprint: fingerprint(canonical),
      deviceSignature: sign(null, canonical, signingPair.privateKey).toString('base64'),
      identitySignature: sign(null, canonical, identity.pair.privateKey).toString('base64'),
    },
  };
}

function proofHeaders(input: {
  method: string;
  target: string;
  credential: string;
  deviceId: string;
  privateKey: ReturnType<typeof generateKeyPairSync>['privateKey'];
  bodyBytes?: Buffer;
}): Record<string, string> {
  const bodySha256 = sha256Hex(input.bodyBytes ?? Buffer.alloc(0));
  const timestampMs = Date.now();
  const nonce = randomBytes(24).toString('base64url');
  const canonical = canonicalDeviceRequestProof({
    method: input.method,
    target: input.target,
    bodySha256,
    timestampMs,
    nonce,
    deviceId: input.deviceId,
    credentialSha256: sha256Hex(input.credential),
  });
  return {
    'x-loom-device-id': input.deviceId,
    'x-loom-request-timestamp': String(timestampMs),
    'x-loom-request-nonce': nonce,
    'x-loom-content-sha256': bodySha256,
    'x-loom-request-signature': sign(null, Buffer.from(canonical), input.privateKey).toString('base64'),
  };
}

async function protectedFetch(input: {
  base: string;
  target: string;
  credential: string;
  deviceId: string;
  privateKey: ReturnType<typeof generateKeyPairSync>['privateKey'];
  method?: string;
  body?: Record<string, unknown>;
  authorization?: boolean;
}) {
  const method = input.method ?? 'GET';
  const bodyText = input.body == null ? undefined : JSON.stringify(input.body);
  const bodyBytes = bodyText == null ? Buffer.alloc(0) : Buffer.from(bodyText);
  const headers: Record<string, string> = {
    accept: 'application/json',
    ...proofHeaders({
      method,
      target: input.target,
      credential: input.credential,
      deviceId: input.deviceId,
      privateKey: input.privateKey,
      bodyBytes,
    }),
  };
  if (input.authorization !== false) headers.authorization = `Bearer ${input.credential}`;
  if (bodyText != null) headers['content-type'] = 'application/json';
  return fetch(`${input.base}${input.target}`, { method, headers, body: bodyText });
}

async function publishDevice(input: {
  base: string;
  accessToken: string;
  deviceId: string;
  bundle: Record<string, unknown>;
}) {
  return fetch(`${input.base}/api/v1/devices/${encodeURIComponent(input.deviceId)}/key-bundle`, {
    method: 'PUT',
    headers: {
      authorization: `Bearer ${input.accessToken}`,
      'content-type': 'application/json',
    },
    body: JSON.stringify(input.bundle),
  });
}

test('authenticated audio/video offers ring over a real socket and replay independently of TURN readiness', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'loom-call-receive-'));
  const callConfig = { ...config(dir), callsEnabled: true, rtcTurnUrls: ['turn:turn.invalid:3478'] };
  const node = new LoomNodeServer(callConfig);
  const bound = await node.listen();
  const base = `http://127.0.0.1:${bound.port}`;
  const sockets: WebSocket[] = [];
  try {
    async function register(username: string) {
      const identity = identityMaterial();
      const response = await fetch(`${base}/api/v1/auth/register`, {
        method: 'POST', headers: { 'content-type': 'application/json' },
        body: JSON.stringify(registrationBody(username, identity)),
      });
      assert.equal(response.status, 201);
      const registration = await response.json() as Record<string, unknown>;
      const credential = String(registration.accessToken);
      const deviceId = String(registration.deviceId);
      const device = deviceMaterial(identity, deviceId);
      assert.equal((await publishDevice({ base, accessToken: credential, deviceId, bundle: device.bundle })).status, 200);
      return { base, credential, deviceId, privateKey: device.signingPair.privateKey, identityId: identity.public.identityId };
    }
    const alice = await register('caller');
    const bob = await register('receiver');
    const created = await protectedFetch({ ...alice, target: '/api/v1/conversations', method: 'POST', body: { address: '@receiver:localhost' } });
    assert.equal(created.status, 201);
    const conversation = await created.json() as { conversationId: string };
    assert.ok(conversation.conversationId);
    const rtc = await protectedFetch({ ...bob, target: '/api/v1/calls/rtc-config' });
    assert.notEqual(rtc.status, 200, 'deliberately incomplete TURN setup');

    async function connect(user: typeof alice) {
      const socket = new WebSocket(base.replace('http:', 'ws:') + '/realtime/v1', {
        headers: { authorization: `Bearer ${user.credential}`, ...proofHeaders({ ...user, method: 'GET', target: '/realtime/v1' }) },
      });
      sockets.push(socket);
      const frames: Array<Record<string, unknown>> = [];
      socket.on('message', (frame) => frames.push(JSON.parse(frame.toString())));
      await new Promise<void>((resolve, reject) => { socket.once('open', resolve); socket.once('error', reject); });
      return { socket, frames };
    }
    async function received(frames: Array<Record<string, unknown>>, predicate: (frame: Record<string, unknown>) => boolean) {
      const deadline = Date.now() + 2_000;
      while (Date.now() < deadline) {
        const match = frames.find(predicate);
        if (match) return match;
        await new Promise((resolve) => setTimeout(resolve, 5));
      }
      assert.fail('expected call frame did not arrive within two seconds');
    }
    const sender = await connect(alice);
    let receiver = await connect(bob);
    for (const kind of ['audio', 'video']) {
      const callId = `real-${kind}`;
      sender.socket.send(JSON.stringify({ kind: 'call.offer', callId, conversationId: conversation.conversationId,
        targetIdentityId: bob.identityId, sequence: 1, mediaKind: kind, sdpType: 'offer', sdp: 'v=0\r\ns=-\r\n' }));
      const offer = await received(receiver.frames, (frame) => frame.callId === callId && frame.kind === 'call.offer');
      assert.equal(offer.senderIdentityId, alice.identityId);
      assert.equal(offer.mediaKind, kind);
      assert.ok(offer.conversationId, 'receiver gets its own valid conversation');

      receiver.socket.close();
      await new Promise<void>((resolve) => receiver.socket.once('close', () => resolve()));
      receiver = await connect(bob);
      await received(receiver.frames, (frame) => frame.callId === callId && frame.kind === 'call.offer');
      receiver.socket.send(JSON.stringify({ kind: 'call.ringing', callId, conversationId: offer.conversationId,
        targetIdentityId: alice.identityId, sequence: 1 }));
      await received(sender.frames, (frame) => frame.callId === callId && frame.kind === 'call.ringing');
      sender.socket.send(JSON.stringify({ kind: 'call.end', callId, conversationId: conversation.conversationId,
        targetIdentityId: bob.identityId, sequence: 2 }));
      await received(receiver.frames, (frame) => frame.callId === callId && frame.kind === 'call.end');
    }
  } finally {
    for (const socket of sockets) socket.terminate();
    await node.close();
    rmSync(dir, { recursive: true, force: true });
  }
});

test('server info, device-bound auth, opaque messaging and sync work in easy mode', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'loom-node-'));
  const node = new LoomNodeServer(config(dir));
  const bound = await node.listen();
  const base = `http://127.0.0.1:${bound.port}`;
  try {
    const infoResponse = await fetch(`${base}/api/v1/server/info`);
    assert.equal(infoResponse.status, 200);
    const info = await infoResponse.json() as Record<string, unknown>;
    assert.equal(info.domain, 'localhost');
    assert.equal(info.serverVersion, '0.10.10');
    assert.equal(info.protocolVersion, 'loom-node-v1');
    assert.ok((info.protocol as string[]).includes('Loom-MLS-v1'));
    assert.ok((info.capabilities as string[]).includes('mls-groups-home-node'));
    assert.match(String(info.nodeId), /^node:/);
    assert.ok((info.capabilities as string[]).includes('device-bound-auth'));

    const readyResponse = await fetch(`${base}/readyz`);
    assert.equal(readyResponse.status, 200);
    const ready = await readyResponse.json() as { ready: boolean; checks: Record<string, boolean> };
    assert.equal(ready.ready, true);
    assert.deepEqual(ready.checks, { database: true, attachments: true, nodeIdentity: true, mlsGroups: true });

    const unauthorizedDiagnostics = await fetch(`${base}/admin/v1/diagnostics`);
    assert.equal(unauthorizedDiagnostics.status, 401);

    const diagnosticsResponse = await fetch(`${base}/admin/v1/diagnostics`, { headers: { authorization: `Bearer ${adminToken}` } });
    assert.equal(diagnosticsResponse.status, 200);
    const diagnostics = await diagnosticsResponse.json() as Record<string, unknown>;
    assert.equal(diagnostics.schemaVersion, 2);
    assert.equal(diagnostics.ready, true);
    assert.equal((diagnostics.calls as Record<string, unknown>).groupCallsEnabled, false);
    assert.equal((diagnostics.calls as Record<string, unknown>).groupCallMaximum, 0);
    assert.equal((diagnostics.security as Record<string, unknown>).clientDeviceProofRequired, true);

    const discoveryResponse = await fetch(`${base}/.well-known/loom/server`);
    assert.equal(discoveryResponse.status, 200);
    const discovery = await discoveryResponse.json() as Record<string, unknown>;
    assert.equal(discovery.endpoint, 'http://localhost');
    assert.equal(discovery.protocol, 'loom-federation-v1');
    assert.equal(discovery.nodeId, info.nodeId);
    assert.equal(discovery.publicKey, info.publicKey);
    assert.ok(String(discovery.signature).length > 64);

    const identity = identityMaterial();
    const registerResponse = await fetch(`${base}/api/v1/auth/register`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(registrationBody('tester', identity)),
    });
    assert.equal(registerResponse.status, 201);
    const registration = await registerResponse.json() as Record<string, unknown>;
    const token = String(registration.accessToken);
    const refreshToken = String(registration.refreshToken);
    const deviceId = String(registration.deviceId);
    assert.equal(registration.address, '@tester:localhost');

    const noBundle = await fetch(`${base}/api/v1/conversations`, {
      headers: { authorization: `Bearer ${token}` },
    });
    assert.equal(noBundle.status, 401);
    assert.deepEqual(await noBundle.json(), { error: 'device_key_bundle_required' });

    const device = deviceMaterial(identity, deviceId);
    const publish = await publishDevice({ base, accessToken: token, deviceId, bundle: device.bundle });
    assert.equal(publish.status, 200);

    const unverifiedProfile = await fetch(`${base}/api/v1/profile`, {
      method: 'PUT', headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
      body: JSON.stringify({displayName: 'Changed', avatar: {png: null, color: 2}}),
    });
    assert.equal(unverifiedProfile.status, 401, 'a bearer alone cannot edit public identity presentation');
    const profile = {displayName: 'Test Profile', avatar: {png: null, color: 4}};
    const editedProfile = await protectedFetch({base, target: '/api/v1/profile', method: 'PUT',
      body: profile, credential: token, deviceId, privateKey: device.signingPair.privateKey});
    assert.equal(editedProfile.status, 200);
    const editedBody = await editedProfile.json() as Record<string, unknown>;
    assert.equal(editedBody.address, '@tester:localhost');
    assert.equal(editedBody.displayName, profile.displayName);
    assert.deepEqual(editedBody.avatar, profile.avatar);
    const readProfile = await protectedFetch({base, target: '/api/v1/profile', credential: token,
      deviceId, privateKey: device.signingPair.privateKey});
    assert.deepEqual(await readProfile.json(), editedBody);
    assert.equal(readProfile.headers.get('cache-control'), 'no-store');
    const invalidProfile = await protectedFetch({base, target: '/api/v1/profile', method: 'PUT',
      body: {...profile, username: 'someone_else'}, credential: token, deviceId, privateKey: device.signingPair.privateKey});
    assert.equal(invalidProfile.status, 400);

    const bearerOnlyAfterBundle = await fetch(`${base}/api/v1/conversations`, {
      headers: { authorization: `Bearer ${token}` },
    });
    assert.equal(bearerOnlyAfterBundle.status, 401);
    assert.deepEqual(await bearerOnlyAfterBundle.json(), { error: 'device_request_proof_required' });

    const forgedIdentity = { ...identity.public, identityId: 'chn:forged-not-derived-from-key' };
    const forgedResponse = await fetch(`${base}/api/v1/auth/register`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ ...registrationBody('forged_user', identity), identity: forgedIdentity }),
    });
    assert.equal(forgedResponse.status, 400);
    assert.deepEqual(await forgedResponse.json(), { error: 'invalid_identity' });

    const duplicateIdentity = identityMaterial();
    const duplicateResponse = await fetch(`${base}/api/v1/auth/register`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(registrationBody('tester', duplicateIdentity)),
    });
    assert.equal(duplicateResponse.status, 409);
    assert.deepEqual(await duplicateResponse.json(), { error: 'username_taken' });

    const conversationsResponse = await protectedFetch({
      base,
      target: '/api/v1/conversations',
      credential: token,
      deviceId,
      privateKey: device.signingPair.privateKey,
    });
    assert.equal(conversationsResponse.status, 200);
    const conversations = await conversationsResponse.json() as { conversations: Array<Record<string, unknown>> };
    assert.equal(conversations.conversations.length, 1);
    const conversationId = String(conversations.conversations[0].id);

    const messageBody = {
      conversationId,
      clientId: 'client-1',
      type: 'TEXT',
      ciphertext: 'opaque-not-plaintext-contract',
      protocolVersion: 'test-envelope-v1',
      metadata: {},
    };
    const send = await protectedFetch({
      base,
      target: '/api/v1/messages',
      method: 'POST',
      body: messageBody,
      credential: token,
      deviceId,
      privateKey: device.signingPair.privateKey,
    });
    assert.equal(send.status, 201);
    const receipt = await send.json() as Record<string, unknown>;
    assert.equal(receipt.clientId, 'client-1');

    const duplicate = await protectedFetch({
      base,
      target: '/api/v1/messages',
      method: 'POST',
      body: messageBody,
      credential: token,
      deviceId,
      privateKey: device.signingPair.privateKey,
    });
    const duplicateReceipt = await duplicate.json() as Record<string, unknown>;
    assert.equal(duplicateReceipt.messageId, receipt.messageId);

    const syncTarget = '/api/v1/sync?limit=200';
    const sync = await protectedFetch({
      base,
      target: syncTarget,
      credential: token,
      deviceId,
      privateKey: device.signingPair.privateKey,
    });
    assert.equal(sync.status, 200);
    const syncBody = await sync.json() as { events: Array<Record<string, unknown>> };
    assert.equal(syncBody.events.length, 1);
    assert.equal(syncBody.events[0].kind, 'message.created');
    const eventPayload = syncBody.events[0].payload as Record<string, unknown>;
    assert.equal(eventPayload.id, receipt.messageId);
    assert.equal(eventPayload.senderAddress, '@tester:localhost');
    assert.equal(eventPayload.senderAccountId, undefined);

    const refreshBody = { refreshToken };
    const refreshResponse = await protectedFetch({
      base,
      target: '/api/v1/auth/refresh',
      method: 'POST',
      body: refreshBody,
      credential: refreshToken,
      deviceId,
      privateKey: device.signingPair.privateKey,
      authorization: false,
    });
    assert.equal(refreshResponse.status, 200);
    const refreshed = await refreshResponse.json() as Record<string, unknown>;
    assert.equal(refreshed.accountId, registration.accountId);
    assert.equal(refreshed.deviceId, registration.deviceId);
    assert.equal(refreshed.address, '@tester:localhost');
    assert.equal(refreshed.refreshToken, refreshToken);
    assert.notEqual(refreshed.accessToken, token);

    const stolenRefresh = await fetch(`${base}/api/v1/auth/refresh`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(refreshBody),
    });
    assert.equal(stolenRefresh.status, 401);
    assert.deepEqual(await stolenRefresh.json(), { error: 'device_request_proof_required' });

    const expiredAccess = await fetch(`${base}/api/v1/conversations`, {
      headers: { authorization: `Bearer ${token}` },
    });
    assert.equal(expiredAccess.status, 401);
    const refreshedToken = String(refreshed.accessToken);
    const refreshedAccess = await protectedFetch({
      base,
      target: '/api/v1/conversations',
      credential: refreshedToken,
      deviceId,
      privateKey: device.signingPair.privateKey,
    });
    assert.equal(refreshedAccess.status, 200);

    const loginResponse = await fetch(`${base}/api/v1/auth/login`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ username: 'tester', password: 'correct horse battery staple', deviceName: 'Second device' }),
    });
    assert.equal(loginResponse.status, 200);
    const login = await loginResponse.json() as Record<string, unknown>;
    assert.equal(login.accountId, registration.accountId);
    assert.equal(login.identityId, identity.public.identityId);
    assert.equal(login.address, '@tester:localhost');
    assert.notEqual(login.deviceId, registration.deviceId, 'password login must create a fresh logical device');
  } finally {
    await node.close();
    rmSync(dir, { recursive: true, force: true });
  }
});

test('approval registration can be reviewed through the admin API without storing plaintext passwords', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'loom-approval-'));
  const node = new LoomNodeServer(config(dir, 'approval'));
  const bound = await node.listen();
  const base = `http://127.0.0.1:${bound.port}`;
  try {
    const pendingIdentity = identityMaterial();
    const submit = await fetch(`${base}/api/v1/auth/register`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(registrationBody('pending_user', pendingIdentity)),
    });
    assert.equal(submit.status, 202);
    const receipt = await submit.json() as Record<string, unknown>;
    const requestId = String(receipt.requestId);
    assert.match(requestId, /^reg_/);
    assert.equal(receipt.status, 'pending');

    const anotherIdentity = identityMaterial();
    const duplicatePending = await fetch(`${base}/api/v1/auth/register`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(registrationBody('pending_user', anotherIdentity)),
    });
    assert.equal(duplicatePending.status, 409);
    assert.deepEqual(await duplicatePending.json(), { error: 'registration_request_exists' });

    const pendingStatus = await fetch(`${base}/api/v1/auth/registrations/${encodeURIComponent(requestId)}`);
    assert.equal(pendingStatus.status, 200);
    assert.equal((await pendingStatus.json() as Record<string, unknown>).status, 'pending');

    const loginBeforeApproval = await fetch(`${base}/api/v1/auth/login`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ username: 'pending_user', password: 'correct horse battery staple' }),
    });
    assert.equal(loginBeforeApproval.status, 401);

    const list = await fetch(`${base}/admin/v1/registrations?status=pending`, {
      headers: { authorization: `Bearer ${adminToken}` },
    });
    assert.equal(list.status, 200);
    const listed = await list.json() as { requests: Array<Record<string, unknown>> };
    assert.equal(listed.requests.length, 1);
    assert.equal(listed.requests[0].requestId, requestId);
    assert.equal(listed.requests[0].username, 'pending_user');
    assert.equal('password' in listed.requests[0], false);
    assert.equal('passwordHash' in listed.requests[0], false);

    const approve = await fetch(`${base}/admin/v1/registrations/${encodeURIComponent(requestId)}/approve`, {
      method: 'POST',
      headers: { authorization: `Bearer ${adminToken}` },
    });
    assert.equal(approve.status, 200);
    const approved = await approve.json() as Record<string, unknown>;
    assert.equal(approved.status, 'approved');
    assert.equal(approved.address, '@pending_user:localhost');

    const approvedStatus = await fetch(`${base}/api/v1/auth/registrations/${encodeURIComponent(requestId)}`);
    const approvedStatusBody = await approvedStatus.json() as Record<string, unknown>;
    assert.equal(approvedStatusBody.status, 'approved');
    assert.equal(approvedStatusBody.address, '@pending_user:localhost');

    const loginAfterApproval = await fetch(`${base}/api/v1/auth/login`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ username: 'pending_user', password: 'correct horse battery staple' }),
    });
    assert.equal(loginAfterApproval.status, 200);
    const login = await loginAfterApproval.json() as Record<string, unknown>;
    assert.equal(login.username, 'pending_user');
    assert.equal(login.address, '@pending_user:localhost');

    const rejectedIdentity = identityMaterial();
    const rejectedSubmit = await fetch(`${base}/api/v1/auth/register`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(registrationBody('rejected_user', rejectedIdentity)),
    });
    assert.equal(rejectedSubmit.status, 202);
    const rejectedReceipt = await rejectedSubmit.json() as Record<string, unknown>;
    const rejectedRequestId = String(rejectedReceipt.requestId);

    const reject = await fetch(`${base}/admin/v1/registrations/${encodeURIComponent(rejectedRequestId)}/reject`, {
      method: 'POST',
      headers: { authorization: `Bearer ${adminToken}`, 'content-type': 'application/json' },
      body: JSON.stringify({ reason: 'Test rejection' }),
    });
    assert.equal(reject.status, 200);
    assert.equal((await reject.json() as Record<string, unknown>).status, 'rejected');

    const rejectedStatus = await fetch(`${base}/api/v1/auth/registrations/${encodeURIComponent(rejectedRequestId)}`);
    const rejectedStatusBody = await rejectedStatus.json() as Record<string, unknown>;
    assert.equal(rejectedStatusBody.status, 'rejected');
    assert.equal(rejectedStatusBody.reason, 'Test rejection');

    const rejectedLogin = await fetch(`${base}/api/v1/auth/login`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ username: 'rejected_user', password: 'correct horse battery staple' }),
    });
    assert.equal(rejectedLogin.status, 401);
  } finally {
    await node.close();
    rmSync(dir, { recursive: true, force: true });
  }
});


test('real HTTP quotas stop login bursts and ignore spoofed forwarded source IPs', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'loom-rate-limit-'));
  const server = new LoomNodeServer(config(dir));
  const address = await server.listen();
  const base = `http://127.0.0.1:${address.port}`;
  try {
    for (let index = 0; index < 30; index++) {
      const response = await fetch(`${base}/api/v1/auth/login`, {
        method: 'POST', headers: {'content-type':'application/json','x-forwarded-for':`203.0.113.${index+1}`},
        body: JSON.stringify({username:`missing${index}`,password:'invalid'})
      });
      assert.equal(response.status, 401); await response.arrayBuffer();
    }
    const limited = await fetch(`${base}/api/v1/auth/login`, {
      method:'POST', headers:{'content-type':'application/json','x-forwarded-for':'198.51.100.250'},
      body:JSON.stringify({username:'another',password:'invalid'})
    });
    assert.equal(limited.status,429); assert.ok(Number(limited.headers.get('retry-after'))>=1);
    assert.equal((await limited.json() as {error:string}).error,'rate_limited');
  } finally {await server.close();rmSync(dir,{recursive:true,force:true});}
});

test('MLS operator endpoints require the admin token and validate requests',async()=>{
 const dir=mkdtempSync(join(tmpdir(),'loom-mls-admin-'));
 const node=new LoomNodeServer(config(dir));const bound=await node.listen();
 const base=`http://127.0.0.1:${bound.port}`;
 const headers={authorization:`Bearer ${adminToken}`,'content-type':'application/json'};
 try {
  for(const [path,method] of [['','GET'],['/missing','GET'],['/missing/policy','POST'],['/key-packages/cleanup','POST']]) {
   for(const token of ['', 'ordinary-client-session']) {
    const r=await fetch(`${base}/admin/v1/groups${path}`,{method,headers:{authorization:`Bearer ${token}`},body:method==='POST'?'{}':undefined});
    assert.equal(r.status,401);
   }
  }
  const registration=await fetch(`${base}/api/v1/auth/register`,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(registrationBody('mlsoperator',identityMaterial()))});
  assert.equal(registration.status,201);
  const ordinary=await registration.json() as Record<string,unknown>;
  const denied=await fetch(`${base}/admin/v1/groups`,{headers:{authorization:`Bearer ${ordinary.accessToken}`}});assert.equal(denied.status,401);
  const list=await fetch(`${base}/admin/v1/groups`,{headers});assert.equal(list.status,200);
  assert.deepEqual(await list.json(),{protocol:'Loom-MLS-v1',groups:[],nextAfter:''});
  assert.equal((await fetch(`${base}/admin/v1/groups?limit=1000`,{headers})).status,400);
  assert.equal((await fetch(`${base}/admin/v1/groups`,{method:'POST',headers,body:'{}'})).status,405);
  assert.equal((await fetch(`${base}/admin/v1/groups/missing`,{headers})).status,404);
  assert.equal((await fetch(`${base}/admin/v1/groups/missing/policy`,{method:'POST',headers,body:JSON.stringify({paused:'yes',expectedPolicyRevision:0})})).status,400);
  const cleaned=await fetch(`${base}/admin/v1/groups/key-packages/cleanup`,{method:'POST',headers});
  assert.deepEqual(await cleaned.json(),{removed:0,limit:1000});
  const d=await (await fetch(`${base}/admin/v1/diagnostics`,{headers})).json() as Record<string,any>;
  assert.equal(d.groups.messagingReady,true);assert.equal(d.groups.groupCount,0);assert.equal(d.groups.availableKeyPackages,0);
  const status=await (await fetch(`${base}/admin/v1/status`,{headers})).json() as Record<string,any>;
  assert.equal(status.groups.protocol,'Loom-MLS-v1');
  const db=new DatabaseSync(join(dir,'loom.sqlite3'));
  try {
   db.prepare('INSERT INTO mls_groups VALUES(?,?)').run('http-group',JSON.stringify({id:'http-group',title:'HTTP group',epoch:7,revision:4,sequence:9,members:[{accountId:ordinary.accountId,deviceId:ordinary.deviceId,identityId:'chn:'+ 'a'.repeat(43),role:'owner',mlsSignatureKey:'redacted-key',mlsSignature:'redacted-signature'}]}));
  }finally{db.close();}
  const inspect=await fetch(`${base}/admin/v1/groups/http-group`,{headers});assert.equal(inspect.status,200);
  const detail=await inspect.json() as Record<string,unknown>;
  assert.equal(detail.epoch,7);assert.ok(!JSON.stringify(detail).includes('redacted-'));
  const policy=await fetch(`${base}/admin/v1/groups/http-group/policy`,{method:'POST',headers,body:JSON.stringify({paused:true,expectedPolicyRevision:0})});assert.equal(policy.status,200);
  const paused=await policy.json() as Record<string,unknown>;
  assert.equal(paused.paused,true);assert.equal(paused.revision,4);assert.equal(paused.policyRevision,1);
  const conflict=await fetch(`${base}/admin/v1/groups/http-group/policy`,{method:'POST',headers,body:JSON.stringify({paused:false,expectedPolicyRevision:0})});assert.equal(conflict.status,409);
  const resume=await fetch(`${base}/admin/v1/groups/http-group/policy`,{method:'POST',headers,body:JSON.stringify({paused:false,expectedPolicyRevision:1})});assert.equal(resume.status,200);
 }finally{await node.close();rmSync(dir,{recursive:true,force:true});}
});


test('public group landing links contain no roster and API previews require a signed session', async () => {
  const dir=mkdtempSync(join(tmpdir(),'loom-invite-page-'));
  const cfg={...config(dir),publicBaseUrl:'https://home.test'};
  const node=new LoomNodeServer(cfg);
  const bound=await node.listen(); const base=`http://127.0.0.1:${bound.port}`;
  try {
    const token='a'.repeat(43);
    const page=await fetch(`${base}/g/${token}`);
    assert.equal(page.status,200);
    assert.equal(page.headers.get('cache-control'),'no-store');
    assert.equal(page.headers.get('referrer-policy'),'no-referrer');
    assert.match(page.headers.get('content-security-policy')!,/frame-ancestors 'none'/);
    const html=await page.text();
    assert.ok(html.includes('loom://group/join?node=https%3A%2F%2Fhome.test%2F&amp;token='+token));
    assert.ok(!html.includes('members') && !html.includes('mlsSignatureKey'));
    for (const target of [`/api/v1/groups/invites/${token}`,`/api/v1/groups/devices/no-device/profile`]) {
      assert.equal((await fetch(base+target)).status,401);
    }
    assert.equal((await fetch(`${base}/g/short`)).status,404);
  } finally { await node.close(); rmSync(dir,{recursive:true,force:true}); }
});
