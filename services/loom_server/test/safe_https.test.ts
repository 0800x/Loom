import test from 'node:test';
import assert from 'node:assert/strict';
import {
  isPrivateOrLocalIp,
  resolveFederationHost,
  unbracketHostname,
} from '../src/federation/safe_https.ts';

test('federation HTTPS rejects private, local and non-routable literal addresses', async () => {
  const rejected = [
    '0.0.0.0',
    '10.0.0.1',
    '100.64.0.1',
    '127.0.0.1',
    '169.254.10.2',
    '172.16.0.1',
    '192.168.1.1',
    '192.0.2.10',
    '198.18.0.1',
    '198.51.100.10',
    '203.0.113.10',
    '224.0.0.1',
    '::',
    '::1',
    'fc00::1',
    'fd00::1',
    'fe80::1',
    'ff02::1',
    '2001:db8::1',
  ];
  for (const address of rejected) {
    assert.equal(isPrivateOrLocalIp(address), true, address);
    await assert.rejects(
      resolveFederationHost(address, false),
      /federation_private_endpoint_rejected/,
      address,
    );
  }
});

test('federation HTTPS permits private literals only in explicit local/hybrid mode', async () => {
  const resolved = await resolveFederationHost('127.0.0.1', true);
  assert.deepEqual(resolved, [{ address: '127.0.0.1', family: 4 }]);
});

test('bracketed IPv6 URL hostnames normalize before literal validation', async () => {
  assert.equal(unbracketHostname('[::1]'), '::1');
  assert.equal(isPrivateOrLocalIp('[::1]'), true);
  const resolved = await resolveFederationHost('[::1]', true);
  assert.deepEqual(resolved, [{ address: '::1', family: 6 }]);
  await assert.rejects(
    resolveFederationHost('[::1]', false),
    /federation_private_endpoint_rejected/,
  );
});

test('federation HTTPS accepts a public literal without a second DNS lookup', async () => {
  const resolved = await resolveFederationHost('8.8.8.8', false);
  assert.deepEqual(resolved, [{ address: '8.8.8.8', family: 4 }]);
});

test('federation HTTPS rejects malformed hostnames before DNS', async () => {
  await assert.rejects(resolveFederationHost('', false), /invalid_federation_hostname/);
  await assert.rejects(resolveFederationHost('bad\nhost', true), /invalid_federation_hostname/);
});
