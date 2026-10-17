import test from 'node:test';
import assert from 'node:assert/strict';

import {
  formatLoomAddress,
  normalizeLoomDomain,
  parseLoomAddress,
} from '../src/federation/address.ts';

test('canonical address supports LAN Home Node host:port authorities', () => {
  const parsed = parseLoomAddress(
    '@alice:192.168.1.4:7483',
    '192.168.1.4:7483',
  );
  assert.equal(parsed.username, 'alice');
  assert.equal(parsed.domain, '192.168.1.4:7483');
  assert.equal(parsed.canonical, '@alice:192.168.1.4:7483');
  assert.equal(parsed.isLocal, true);
});

test('remote authority remains federation-aware when a port is present', () => {
  const parsed = parseLoomAddress(
    '@bob:node-b.example:8443',
    'node-a.example:8443',
  );
  assert.equal(parsed.domain, 'node-b.example:8443');
  assert.equal(parsed.isLocal, false);
});

test('formatting and normalization keep the existing user:home-node contract', () => {
  assert.equal(
    formatLoomAddress('Alice', 'NODE-A.EXAMPLE'),
    '@alice:node-a.example',
  );
  assert.equal(normalizeLoomDomain('node-a.example:8443'), 'node-a.example:8443');
});

test('Home Node paths and credentials remain invalid', () => {
  assert.throws(() => normalizeLoomDomain('node.example/path'));
  assert.throws(() => normalizeLoomDomain('alice@node.example'));
});
