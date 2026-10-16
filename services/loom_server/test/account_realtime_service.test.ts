import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import type { WebSocket } from 'ws';
import { LoomAccountRealtimeService } from '../src/messaging/account_realtime_service.ts';

class Socket extends EventEmitter {
  readyState = 1;
  bufferedAmount = 0;
  frames: Array<Record<string, unknown>> = [];
  closeCode?: number;
  send(frame: string) { this.frames.push(JSON.parse(frame)); }
  close(code: number) { this.closeCode = code; this.readyState = 3; this.emit('close'); }
  ping() { this.emit('pong'); }
  terminate() { this.close(1006); }
  asWs() { return this as unknown as WebSocket; }
}
const turn = () => new Promise<void>(resolve => setImmediate(resolve));

test('account stream delivers committed events immediately, isolates accounts and resumes the supplied cursor', async () => {
  const events = new Map<string, Array<Record<string, unknown>>>([['alice', [{eventId:'a1'}, {eventId:'a2'}]], ['bob', [{eventId:'b1'}]]]);
  const hub = new LoomAccountRealtimeService(async (account, cursor) => {
    const all = events.get(account)!;
    return { events: all.slice(Number(cursor ?? 0)), nextCursor: String(all.length), hasMore: false };
  }, 0);
  try {
    const alice = new Socket(), bob = new Socket();
    hub.attach('alice', alice.asWs(), '1'); hub.attach('bob', bob.asWs(), null);
    await turn();
    assert.deepEqual(alice.frames, [{eventId:'a2'}]);
    assert.deepEqual(bob.frames, [{eventId:'b1'}]);
    events.get('alice')!.push({eventId:'a3'});
    hub.notifyCommitted(); await turn();
    assert.deepEqual(alice.frames.map(e => e.eventId), ['a2','a3']);
    assert.equal(bob.frames.length, 1);
    alice.close(1000); events.get('alice')!.push({eventId:'a4'});
    hub.notifyCommitted(); await turn();
    assert.equal(alice.frames.length, 2);
  } finally { hub.close(); }
});

test('concurrent wakeups serialize cursor reads and drain paginated catchup without dropping events', async () => {
  let inFlight = 0, maxInFlight = 0;
  const hub = new LoomAccountRealtimeService(async (_, cursor) => {
    inFlight++; maxInFlight = Math.max(inFlight,maxInFlight); await turn(); inFlight--;
    const n = Number(cursor ?? 0);
    return {events: n < 3 ? [{eventId:`e${n}`}]:[], nextCursor:String(Math.min(n+1,3)),hasMore:n<2};
  }, 0);
  try {
    const socket = new Socket(); hub.attach('alice',socket.asWs(),null);
    hub.notifyCommitted(); hub.notifyCommitted();
    for (let i=0;i<12;i++) await turn();
    assert.equal(maxInFlight,1);
    assert.deepEqual(socket.frames.map(e=>e.eventId),['e0','e1','e2']);
  } finally { hub.close(); }
});

test('slow clients and failed cursor reads close explicitly for durable REST recovery', async () => {
  for (const fails of [false,true]) {
    const hub = new LoomAccountRealtimeService(async () => {
      if(fails) throw new Error('storage unavailable');
      return {events:[{eventId:'pending'}],nextCursor:'1',hasMore:false};
    },0);
    try {
      const socket = new Socket(); socket.bufferedAmount=2*1024*1024;
      hub.attach('alice',socket.asWs(),null); await turn();
      assert.equal(socket.closeCode,fails?1011:1013);
      assert.equal(socket.frames.length,0);
    } finally {hub.close();}
  }
});


test('public connected count deduplicates multiple devices of the same user', async () => {
  const hub = new LoomAccountRealtimeService(async () => ({events: [], nextCursor: '0', hasMore: false}), 0);
  try {
    const a = new Socket(), b = new Socket(), c = new Socket();
    hub.attach('alice', a.asWs(), null); hub.attach('alice', b.asWs(), null); hub.attach('bob', c.asWs(), null);
    assert.equal(hub.connectedAccountCount(), 2);
    a.close(1000); assert.equal(hub.connectedAccountCount(), 2);
    b.close(1000); assert.equal(hub.connectedAccountCount(), 1);
  } finally { hub.close(); }
});
