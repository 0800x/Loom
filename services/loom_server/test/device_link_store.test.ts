import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash, randomBytes } from 'node:crypto';
import type { SessionInfo } from '../src/storage/sqlite_store.ts';
import { DeviceLinkStore } from '../src/security/device_link_store.ts';

function session(input: Partial<SessionInfo> = {}): SessionInfo {
  return {
    accountId: 'acct-1',
    identityId: 'chn:identity-1',
    username: 'alice',
    deviceId: 'dev_11111111-1111-1111-1111-111111111111',
    ...input,
  };
}

function token(): string {
  return randomBytes(32).toString('base64url');
}

function hash(value: string): string {
  return createHash('sha256').update(value, 'utf8').digest('hex');
}

test('device-link invitation is same-account and target-device bound', () => {
  const linkId = 'dl_ABCDEFGHIJKLMNOPQRSTUVWXYZabcd';
  const payload = sealedPayload();
  const store = new DeviceLinkStore();
  const source = session();
  const target = session({
    deviceId: 'dev_22222222-2222-2222-2222-222222222222',
  });
  const otherTarget = session({
    deviceId: 'dev_33333333-3333-3333-3333-333333333333',
  });
  const secret = token();

  const created = store.create(source, {
    linkId,
    tokenHash: hash(secret),
    payload,
  });
  assert.equal(created.sourceDeviceId, source.deviceId);
  assert.equal(created.targetDeviceId, null);

  const redeemed = store.redeem(target, linkId, secret);
  assert.equal(redeemed.payload, payload);
  assert.equal(redeemed.targetDeviceId, target.deviceId);

  assert.throws(
    () => store.redeem(otherTarget, linkId, secret),
    /device_link_target_mismatch/,
  );

  store.complete(target, linkId);
  assert.throws(
    () => store.redeem(target, linkId, secret),
    /device_link_not_found/,
  );
});

test('device-link rejects wrong account and wrong token', () => {
  const store = new DeviceLinkStore();
  const source = session();
  const target = session({
    deviceId: 'dev_44444444-4444-4444-4444-444444444444',
  });
  const wrongAccount = session({
    accountId: 'acct-2',
    identityId: 'chn:identity-2',
    deviceId: 'dev_55555555-5555-5555-5555-555555555555',
  });
  const secret = token();
  const linkId = 'dl_abcdefghijklmnopqrstuvwxyzABCD';

  // DeviceLinkStore intentionally rejects tiny opaque packages (< 32 bytes),
  // so this negative-token test must first create an otherwise valid invite.
  store.create(source, {
    linkId,
    tokenHash: hash(secret),
    payload: sealedPayload(),
  });

  assert.throws(
    () => store.redeem(target, linkId, token()),
    /device_link_token_mismatch/,
  );
  assert.throws(
    () => store.redeem(wrongAccount, linkId, secret),
    /device_link_account_mismatch/,
  );
});


function sealedPayload(): string {
  return JSON.stringify({v:2,protocol:'loom-device-link-v2',nonce:randomBytes(12).toString('base64'),ciphertext:randomBytes(64).toString('base64'),mac:randomBytes(16).toString('base64')});
}

test('relay refuses legacy token-derived envelopes and secret-bearing payloads', () => {
  const store=new DeviceLinkStore();
  const invitation={linkId:'dl_ABCDEFGHIJKLMNOPQRSTUVWXYZabcd',tokenHash:hash(token())};
  for(const payload of [JSON.stringify({...JSON.parse(sealedPayload()),v:1,protocol:'loom-device-link-v1'}),JSON.stringify({...JSON.parse(sealedPayload()),encryptionSecret:token()})]) {
    assert.throws(()=>store.create(session(),{...invitation,payload}),/invalid_device_link_payload/);
  }
});
