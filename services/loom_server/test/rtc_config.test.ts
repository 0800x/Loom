import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import test from 'node:test';

import { buildRtcConfiguration, rtcReady } from '../src/calls/rtc_config.ts';
import type { LoomNodeConfig } from '../src/config/config.ts';
import type { SessionInfo } from '../src/storage/sqlite_store.ts';

const session: SessionInfo = {
  accountId: 'acc_test',
  deviceId: 'dev_00000000-0000-0000-0000-000000000001',
  username: 'alice',
  identityId: 'chn:test-identity',
};

function config(overrides: Partial<LoomNodeConfig> = {}): LoomNodeConfig {
  return {
    schemaVersion: 1,
    mode: 'easy',
    listenHost: '127.0.0.1',
    listenPort: 7483,
    publicDomain: 'localhost:7483',
    publicBaseUrl: 'http://localhost:7483',
    dataDirectory: '/tmp/loom-test',
    attachmentsDirectory: '/tmp/loom-test/attachments',
    registrationPolicy: 'open',
    federationMode: 'disabled',
    networkJurisdiction: 'test',
    operatorName: 'test',
    adminToken: 'x'.repeat(32),
    maxAttachmentBytes: 1024 * 1024,
    maxRequestBytes: 1024 * 1024,
    callsEnabled: true,
    ...overrides,
  };
}

test('STUN-only development configuration is returned without credentials', () => {
  const response = buildRtcConfiguration(
    config({ rtcStunUrls: ['stun:stun.example.test:3478'] }),
    session,
    Date.UTC(2026, 8, 5, 10),
  );
  assert.deepEqual(response.iceServers, [
    { urls: ['stun:stun.example.test:3478'] },
  ]);
});

test('TURN credentials are short lived and bind identity plus device', () => {
  const secret = 's'.repeat(48);
  const now = Date.UTC(2026, 8, 5, 10);
  const response = buildRtcConfiguration(
    config({
      mode: 'production',
      publicDomain: 'chat.example.test',
      publicBaseUrl: 'https://chat.example.test',
      rtcTurnUrls: [
        'turn:turn.example.test:3478?transport=udp',
        'turn:turn.example.test:3478?transport=tcp',
        'turns:turn.example.test:5349?transport=tcp',
      ],
      rtcTurnSharedSecret: secret,
      rtcCredentialTtlSeconds: 300,
    }),
    session,
    now,
  );

  assert.equal(response.iceServers.length, 1);
  const turn = response.iceServers[0];
  assert.deepEqual(turn.urls, [
    'turn:turn.example.test:3478?transport=udp',
    'turn:turn.example.test:3478?transport=tcp',
    'turns:turn.example.test:5349?transport=tcp',
  ]);
  assert.match(turn.username ?? '', /^\d+:chn:test-identity:dev_/);
  assert.equal(
    turn.credential,
    createHmac('sha1', secret).update(turn.username!).digest('base64'),
  );
  assert.equal(Date.parse(response.expiresAt), now + 300_000);
  assert.ok(!JSON.stringify(response).includes(secret));
});

test('production RTC readiness requires authenticated TURN', () => {
  assert.equal(
    rtcReady(config({ mode: 'production', callsEnabled: true })),
    false,
  );
  assert.equal(
    rtcReady(
      config({
        mode: 'production',
        callsEnabled: true,
        rtcTurnUrls: ['turns:turn.example.test:5349'],
        rtcTurnSharedSecret: 's'.repeat(32),
      }),
    ),
    true,
  );
});

test('configured TURN is never returned unauthenticated', () => {
  assert.throws(
    () => buildRtcConfiguration(
      config({ rtcTurnUrls: ['turn:turn.example.test:3478'] }),
      session,
    ),
    /turn_credentials_unavailable/,
  );
});

test('disabled calls do not issue RTC configuration', () => {
  assert.throws(
    () => buildRtcConfiguration(config({ callsEnabled: false }), session),
    /calls_disabled/,
  );
});
