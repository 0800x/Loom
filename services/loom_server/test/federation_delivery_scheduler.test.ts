import test from 'node:test';
import assert from 'node:assert/strict';
import type { LoomNodeConfig } from '../src/config/config.ts';
import type { LoomNodeIdentity } from '../src/identity/node_identity.ts';
import type { FederationNodeRegistry } from '../src/federation/node_registry.ts';
import type { FederationRoutingStore } from '../src/federation/routing_store.ts';
import { FederationService } from '../src/federation/service.ts';

test('deliverDue immediately drains a request queued while another pass is active', async () => {
  let releaseFirstPass!: () => void;
  const firstPassGate = new Promise<void>((resolve) => {
    releaseFirstPass = resolve;
  });

  let announceFirstPass!: () => void;
  const firstPassStarted = new Promise<void>((resolve) => {
    announceFirstPass = resolve;
  });

  let dueCalls = 0;
  const routing = {
    async dueDeliveries() {
      dueCalls += 1;
      if (dueCalls === 1) {
        announceFirstPass();
        await firstPassGate;
      }
      return [];
    },
  } as unknown as FederationRoutingStore;

  const service = new FederationService(
    { federationMode: 'open' } as LoomNodeConfig,
    {} as LoomNodeIdentity,
    {} as FederationNodeRegistry,
    routing,
  );

  const firstRun = service.deliverDue();
  await firstPassStarted;

  // This kick arrives while the first pass is blocked. It must not be lost or
  // deferred to the one-second periodic sweep.
  await service.deliverDue();
  assert.equal(dueCalls, 1);

  releaseFirstPass();
  await firstRun;

  assert.equal(dueCalls, 2);
});

test('multiple kicks during one active pass coalesce into one immediate follow-up pass', async () => {
  let releaseFirstPass!: () => void;
  const firstPassGate = new Promise<void>((resolve) => {
    releaseFirstPass = resolve;
  });

  let announceFirstPass!: () => void;
  const firstPassStarted = new Promise<void>((resolve) => {
    announceFirstPass = resolve;
  });

  let dueCalls = 0;
  const routing = {
    async dueDeliveries() {
      dueCalls += 1;
      if (dueCalls === 1) {
        announceFirstPass();
        await firstPassGate;
      }
      return [];
    },
  } as unknown as FederationRoutingStore;

  const service = new FederationService(
    { federationMode: 'open' } as LoomNodeConfig,
    {} as LoomNodeIdentity,
    {} as FederationNodeRegistry,
    routing,
  );

  const firstRun = service.deliverDue();
  await firstPassStarted;

  await Promise.all([
    service.deliverDue(),
    service.deliverDue(),
    service.deliverDue(),
  ]);

  releaseFirstPass();
  await firstRun;

  assert.equal(dueCalls, 2);
});

import { FederationDeliveryScheduler } from '../src/federation/delivery_scheduler.ts';
import type { OutboxDelivery } from '../src/federation/routing_store.ts';

const turn = () => new Promise<void>(resolve => setImmediate(resolve));
function queued(id: string, node: string): OutboxDelivery {
  return {deliveryId:id,destinationNodeId:node} as OutboxDelivery;
}

test('a slow destination does not block a new healthy destination or occupy every worker', async () => {
  const pending = [queued('slow-1','slow'),queued('slow-2','slow')];
  const started: string[] = [];
  let release!: () => void;
  const gate = new Promise<void>(resolve => {release=resolve;});
  const errors: unknown[] = [];
  const scheduler = new FederationDeliveryScheduler(async (limit,busy) => {
    const selected = new Set(busy);
    return pending.filter(d => {
      if (selected.has(d.destinationNodeId)) return false;
      selected.add(d.destinationNodeId); return true;
    }).slice(0,limit);
  }, async delivery => {
    started.push(delivery.deliveryId);
    if (delivery.destinationNodeId==='slow') await gate;
    pending.splice(pending.indexOf(delivery),1);
  }, error => errors.push(error), 2);
  try {
    await scheduler.kick(); await turn();
    assert.deepEqual(started,['slow-1']);
    pending.push(queued('fast-1','fast'));
    await scheduler.kick(); await turn();
    // Still no response from slow, but fast has already completed.
    assert.deepEqual(started,['slow-1','fast-1']);
    assert.equal(scheduler.inFlight,1);
    assert.deepEqual(errors,[]);
  } finally {scheduler.stop();release();await turn();}
});

test('a completed worker immediately takes another Node without waiting for its batch peers', async () => {
  const pending = [queued('a','a'),queued('b','b'),queued('c','c')];
  const releases = new Map<string,() => void>();
  const started: string[] = [];
  let maximum = 0;
  const scheduler = new FederationDeliveryScheduler(async (limit,busy) => pending.filter(d=>!busy.includes(d.destinationNodeId)).slice(0,limit), async d => {
    started.push(d.deliveryId);
    maximum=Math.max(maximum,scheduler.inFlight);
    await new Promise<void>(resolve => releases.set(d.deliveryId,resolve));
    pending.splice(pending.indexOf(d),1);
  }, error => {throw error;}, 2);
  try {
    await scheduler.kick(); await turn();
    assert.deepEqual(started,['a','b']);
    releases.get('b')!(); await turn();
    assert.deepEqual(started,['a','b','c']);
    assert.equal(maximum,2);
  } finally {scheduler.stop();for(const release of releases.values())release();await turn();}
});

test('store failure is contained and waits for another sweep rather than spinning', async () => {
  let calls=0;
  const errors: unknown[]=[];
  const scheduler=new FederationDeliveryScheduler(async()=>[queued('a','a')],async()=>{calls++;throw new Error('storage busy');},error=>errors.push(error));
  await scheduler.kick();await turn();await turn();
  assert.equal(calls,1);assert.equal(errors.length,1);assert.equal(scheduler.inFlight,0);
  scheduler.stop();await scheduler.kick();assert.equal(calls,1);
});
