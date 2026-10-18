import test from 'node:test';
import assert from 'node:assert/strict';
import { BoundedMap } from '../src/security/bounded_map.ts';
import { RateLimitError } from '../src/security/rate_limiter.ts';
import { GroupCallService } from '../src/calls/group_call_service.ts';

test('live entries cannot be evicted or extended beyond configured capacity',()=>{
 const map=new BoundedMap<string,number>(2);map.set('a',1);map.set('b',2);
 for(let i=0;i<1000;i++)assert.throws(()=>map.set(String(i),i),RateLimitError);
 assert.equal(map.get('a'),1);map.set('a',3);assert.equal(map.size,2);
 map.delete('b');map.set('c',4);assert.equal(map.size,2);
});
test('group-control serialization bounds waiting promises and releases capacity',async()=>{
 const service=Object.assign(Object.create(GroupCallService.prototype),{queues:new Map(),pendingControls:0,perGroupControls:new Map()}) as unknown as {serial:(id:string,fn:()=>Promise<void>)=>Promise<void>};
 let release!:()=>void;const gate=new Promise<void>(r=>release=r);
 const pending=Array.from({length:32},()=>service.serial('room',()=>gate));
 const timer=setTimeout(release,30);
 await assert.rejects(service.serial('room',async()=>{}),RateLimitError);
 clearTimeout(timer);
 release();await Promise.all(pending);await service.serial('room',async()=>{});
});
