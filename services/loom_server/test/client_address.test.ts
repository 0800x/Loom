import test from 'node:test';
import assert from 'node:assert/strict';
import type { IncomingMessage } from 'node:http';
import { LoomClientAddressPolicy } from '../src/security/client_address.ts';
const request = (ip: string, forwarded?: string) => ({ socket: { remoteAddress: ip }, headers: { 'x-forwarded-for': forwarded } }) as unknown as IncomingMessage;

test('forwarded identities are ignored unless the TCP peer is explicitly trusted', () => {
  assert.equal(new LoomClientAddressPolicy().address(request('203.0.113.2', '1.2.3.4')), '203.0.113.2');
  const policy = new LoomClientAddressPolicy('127.0.0.1/32,::1/128,10.0.0.0/24');
  assert.equal(policy.address(request('203.0.113.2', '1.2.3.4')), '203.0.113.2');
  assert.equal(policy.address(request('::ffff:127.0.0.1', '198.51.100.4')), '198.51.100.4');
  assert.equal(policy.address(request('::1', '198.51.100.4, 10.0.0.2')), '198.51.100.4');
  assert.equal(policy.address(request('127.0.0.1', '1.2.3.4, 203.0.113.2')), '203.0.113.2');
});

test('malformed chains fail closed to the socket peer and invalid trust config fails startup', () => {
  const policy = new LoomClientAddressPolicy('127.0.0.1/32');
  for (const chain of ['unknown', '1.2.3.4:80', '1.2.3.4,', '1.2.3.4, garbage', Array(18).fill('1.2.3.4').join(',')]) {
    assert.equal(policy.address(request('127.0.0.1', chain)), '127.0.0.1');
  }
  for (const config of ['*', 'localhost', '0.0.0.0/0', '::/0', '10.0.0.1/33', '::1/129', '127.0.0.1/32,']) {
    assert.throws(() => new LoomClientAddressPolicy(config));
  }
});
