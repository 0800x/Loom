import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { generateKeyPairSync, sign } from 'node:crypto';
import { GroupStore, keyPackageBinding, mlsDeviceBinding } from '../src/groups/group_store.ts';
import type { SessionInfo } from '../src/storage/sqlite_store.ts';

const wire = Buffer.from('opaque MLS data').toString('base64');
function fixture() {
  const db = new DatabaseSync(':memory:');
  db.exec(`CREATE TABLE accounts(id TEXT PRIMARY KEY,identity_id TEXT,username TEXT,display_name TEXT); CREATE TABLE device_key_bundles(device_id TEXT,account_id TEXT,identity_id TEXT,signing_public_key TEXT); CREATE TABLE devices(id TEXT PRIMARY KEY,account_id TEXT,revoked_at TEXT); CREATE TABLE conversations(id TEXT PRIMARY KEY,kind TEXT,title TEXT,created_at TEXT); CREATE TABLE conversation_members(conversation_id TEXT,account_id TEXT,PRIMARY KEY(conversation_id,account_id));`);
  const sessions = ['a','b','c'].map(n => ({ accountId: 'account-'+n, deviceId: 'device-'+n, identityId: 'chn:'+n.repeat(43), username: n }));
  for (const s of sessions) { db.prepare('INSERT INTO devices VALUES(?,?,NULL)').run(s.deviceId,s.accountId); db.prepare('INSERT INTO accounts VALUES(?,?,?,?)').run(s.accountId,s.identityId,s.username,s.username); }
  const store = new GroupStore(db);
  const keys = generateKeyPairSync('ed25519');
  const publicKey = keys.publicKey.export({type:'spki',format:'der'}).subarray(-32).toString('base64');
  async function publish(s: SessionInfo, id: string) {
    const p = {id,serialized:wire,expiresAt:new Date(Date.now()+86400000).toISOString(),signature:''};
    p.signature=sign(null,keyPackageBinding(s,p),keys.privateKey).toString('base64');
    await store.publish(s,p,publicKey); return p;
  }
  for (const s of sessions) db.prepare('INSERT INTO device_key_bundles VALUES(?,?,?,?)').run(s.deviceId,s.accountId,s.identityId,publicKey);
  const members = sessions.slice(0,2).map((s,i) => {
    const m={accountId:s.accountId,deviceId:s.deviceId,identityId:s.identityId,mlsSignatureKey:Buffer.alloc(32,i+1).toString('base64'),mlsSignature:'',role:i===0?'owner':'member'};
    m.mlsSignature=sign(null,mlsDeviceBinding(m),keys.privateKey).toString('base64'); return m;
  });
  async function create() {
    await publish(sessions[1],'package-b'); const claim = await store.claim(sessions[0],sessions[1].deviceId);
    const request = {operationId:'create',title:'Friends',epoch:1,members,commit:wire,welcomes:{'device-b':wire},claims:{'device-b':claim.claimId}};
    await store.create(sessions[0],'group-1',request); return request;
  }
  return {db,store,sessions,publish,members,create,publicKey,keys};
}
import { GroupCallService } from '../src/calls/group_call_service.ts';
import { LiveKitGroupCallMedia,type GroupCallMedia,type MediaPermission } from '../src/calls/group_call_media.ts';
import {createDefaultConfig,validateConfig} from '../src/config/config.ts';
import type {GroupCallRecord,GroupCallParticipant} from '../src/calls/group_call_policy.ts';
import {AccessToken,TokenVerifier} from 'livekit-server-sdk';
import {createHash} from 'node:crypto';
class Media implements GroupCallMedia {
  grants:{p:string;permission:MediaPermission}[]=[];removed:string[]=[];closed:string[]=[];
  async create(_:GroupCallRecord){}
  async remove(_:string,p:string){this.removed.push(p);}
  async close(room:string){this.closed.push(room);}
  async permission(_:string,p:string,permission:MediaPermission){this.grants.push({p,permission});}
  async token(c:GroupCallRecord,p:GroupCallParticipant){return JSON.stringify({identity:p.id,room:c.room});}
  async verify(t:string){return JSON.parse(t);}
  async webhook(body:string,signature:string){if(signature!=='signed')throw new Error('signature');return JSON.parse(body);}
}
async function setup(){
  const f=fixture();await f.create();let now=1000000;
  const config=createDefaultConfig();config.callsEnabled=true;config.publicBaseUrl='https://home.test';config.groupCalls={enabled:true,apiUrl:'http://127.0.0.1:7880',apiKey:'test-key',apiSecret:'s'.repeat(40),maxParticipants:2};
  const media=new Media(),calls=new GroupCallService(config,f.store,{media,clock:()=>now,timers:false});
  const start=await calls.start(f.sessions[0],'group-1',{kind:'video',mode:'approval'}),id=start.call!.id;
  async function join(index:number){const result=await calls.join(f.sessions[index],'group-1',{callId:id});await calls.webhook(JSON.stringify({id:'join-'+index,event:'participant_joined',room:{name:'gc_'+id},participant:{identity:result.participantId,sid:'sid-'+index}}),'signed');return result;}
  return {...f,config,media,calls,id,join,advance:(ms:number)=>{now+=ms;},cleanup:async()=>{await calls.close();f.db.close();}};
}
test('moderation changes actual SFU sources; account removal blocks rejoin and old JWTs',async()=>{
 const f=await setup();try{
  const owner=await f.join(0),member=await f.join(1),grant=()=>f.media.grants.filter(g=>g.p===member.participantId).at(-1)!.permission;
  assert.deepEqual(grant(),{subscribe:true,microphone:false,camera:false});
  await assert.rejects(f.calls.control(f.sessions[1],'group-1',{callId:f.id,action:'allow_speak',participantId:owner.participantId}),/admin_required/);
  await f.calls.control(f.sessions[1],'group-1',{callId:f.id,action:'raise_hand'});
  await f.calls.control(f.sessions[0],'group-1',{callId:f.id,action:'allow_speak',participantId:member.participantId});assert.deepEqual(grant(),{subscribe:true,microphone:true,camera:true});
  await f.calls.control(f.sessions[0],'group-1',{callId:f.id,action:'mute',participantId:member.participantId});assert.deepEqual(grant(),{subscribe:true,microphone:false,camera:true});
  await f.calls.control(f.sessions[0],'group-1',{callId:f.id,action:'disable_camera',participantId:member.participantId});assert.deepEqual(grant(),{subscribe:true,microphone:false,camera:false});
  await f.calls.control(f.sessions[0],'group-1',{callId:f.id,action:'remove',participantId:member.participantId});assert.ok(f.media.removed.includes(member.participantId));
  await assert.rejects(f.calls.authorize(member.token),/removed/);await assert.rejects(f.calls.join(f.sessions[1],'group-1',{callId:f.id}),/removed/);
  await f.calls.webhook(JSON.stringify({id:'late',event:'participant_joined',room:{name:'gc_'+f.id},participant:{identity:member.participantId,sid:'new'}}),'signed');
  assert.equal((await f.calls.view(f.sessions[0],'group-1')).call!.participants.some(p=>p.id===member.participantId),false);
 }finally{await f.cleanup();}
});
test('revoked devices and changed MLS epochs invalidate media and empty ended DTOs',async()=>{
 const f=await setup();try{
  const member=await f.join(1),admission=await f.calls.authorize(member.token);
  f.db.prepare("UPDATE devices SET revoked_at='revoked' WHERE id='device-b'").run();assert.equal(await f.calls.stillAuthorized(admission),false);await assert.rejects(f.calls.authorize(member.token),/removed/);
  await f.calls.membershipChanged('group-1');assert.ok(f.media.removed.includes(member.participantId));
  await f.store.commit(f.sessions[0],'group-1',1,{operationId:'remove-b',epoch:2,title:'Friends',members:[f.members[0]],commit:wire,welcomes:{},claims:{}});await f.calls.membershipChanged('group-1');assert.ok(f.media.closed.includes('gc_'+f.id));
  const call=(await f.calls.view(f.sessions[0],'group-1')).call!;assert.equal(call.phase,'ended');assert.deepEqual(call.participants,[]);
 }finally{await f.cleanup();}
});
test('hand requests rate limit, settings CAS and expired authorization fail closed',async()=>{
 const f=await setup();try{
  const member=await f.join(1);await f.join(0);
  await f.calls.control(f.sessions[1],'group-1',{callId:f.id,action:'raise_hand'});await f.calls.control(f.sessions[1],'group-1',{callId:f.id,action:'lower_hand'});
  await assert.rejects(f.calls.control(f.sessions[1],'group-1',{callId:f.id,action:'raise_hand'}),/rate_limited/);
  await assert.rejects(f.calls.control(f.sessions[0],'group-1',{callId:f.id,action:'set_mode',mode:'open',expectedRevision:1}),/changed/);
  const revision=(await f.calls.view(f.sessions[0],'group-1')).call!.revision;await f.calls.control(f.sessions[0],'group-1',{callId:f.id,action:'set_mode',mode:'open',expectedRevision:revision});
  assert.equal(f.media.grants.filter(g=>g.p===member.participantId).at(-1)!.permission.microphone,true);
  const admission=await f.calls.authorize(member.token);f.advance(16000);assert.equal(await f.calls.stillAuthorized(admission),false);await assert.rejects(f.calls.heartbeat(f.sessions[1],'group-1',{callId:f.id}),/removed/);
 }finally{await f.cleanup();}
});
test('signed webhook replay is idempotent and stale leave cannot undo reconnect',async()=>{
 const f=await setup();try{
  const m=await f.join(1),body=JSON.stringify({id:'reconnect',event:'participant_joined',room:{name:'gc_'+f.id},participant:{identity:m.participantId,sid:'new'}});
  const before=(await f.calls.view(f.sessions[0],'group-1')).call!.revision;await Promise.all([f.calls.webhook(body,'signed'),f.calls.webhook(body,'signed')]);assert.equal((await f.calls.view(f.sessions[0],'group-1')).call!.revision,before+1);
  await assert.rejects(f.calls.webhook(body,'bad'),/webhook/);
  await f.calls.webhook(JSON.stringify({id:'old-left',event:'participant_left',room:{name:'gc_'+f.id},participant:{identity:m.participantId,sid:'sid-1'}}),'signed');assert.equal((await f.calls.view(f.sessions[0],'group-1')).call!.participants[0].state,'connected');
 }finally{await f.cleanup();}
});
test('real SFU JWTs have zero grants, refreshed grants are stripped and raw-body hash is verified',async()=>{
 const f=await setup();try{
  const m=await f.join(1),settings=f.config.groupCalls!,media=new LiveKitGroupCallMedia(settings);
  const jwt=new AccessToken(settings.apiKey,settings.apiSecret,{identity:m.participantId});jwt.addGrant({room:'gc_'+f.id,roomJoin:true,canPublish:true,canSubscribe:true,canPublishData:true});
  const service=new GroupCallService(f.config,f.store,{media,timers:false,clock:()=>1000000});
  try{const a=await service.authorize(await jwt.toJwt()),claims=await new TokenVerifier(settings.apiKey,settings.apiSecret).verify(a.upstreamToken);assert.equal(claims.video!.canPublish,false);assert.equal(claims.video!.canSubscribe,false);assert.equal(claims.video!.canPublishData,false);}finally{await service.close();}
  const body=JSON.stringify({id:'event',event:'room_started',room:{name:'gc_'+f.id}}),signature=new AccessToken(settings.apiKey,settings.apiSecret);signature.sha256=createHash('sha256').update(body).digest('base64');
  assert.equal((await media.webhook(body,await signature.toJwt())).event,'room_started');await assert.rejects(media.webhook(body+' ',await signature.toJwt()));await assert.rejects(media.verify('bad'));
 }finally{await f.cleanup();}
});
test('SFU configuration rejects reused secrets, unsafe origins and unsupported capacity',()=>{
 const c=createDefaultConfig();c.groupCalls={enabled:true,apiUrl:'http://livekit:7880',apiKey:'test-key',apiSecret:'z'.repeat(40),maxParticipants:16};validateConfig(c);
 for(const apiUrl of ['ftp://livekit','http://user:password@livekit','http://livekit/path','http://livekit?query=1'])assert.throws(()=>validateConfig({...c,groupCalls:{...c.groupCalls!,apiUrl}}));
 assert.throws(()=>validateConfig({...c,groupCalls:{...c.groupCalls!,apiSecret:c.adminToken}}));assert.throws(()=>validateConfig({...c,groupCalls:{...c.groupCalls!,maxParticipants:33}}));
});
import {startGroupCall,joinGroupCall,type GroupCallAuthority} from '../src/calls/group_call_policy.ts';
test('ordinary accounts cannot fill the reserved moderation seat',async()=>{
 const f=fixture();try{
  await f.create();const group=await f.store.get(f.sessions[0],'group-1');
  group.members.push({...group.members[1],accountId:'account-c',deviceId:'device-c',identityId:f.sessions[2].identityId});
  const a:GroupCallAuthority={group,actor:group.members[0],activeDevices:new Set(group.members.map(m=>m.deviceId)),paused:false,call:null};
  const room=startGroupCall(a,'audio','open',1000);a.actor=group.members[1];joinGroupCall(a,room.id,'Bob',2,1000);
  a.actor=group.members[2];assert.throws(()=>joinGroupCall(a,room.id,'Carol',2,1000),/full/);
  a.actor=group.members[0];joinGroupCall(a,room.id,'Owner',2,1000);assert.equal(a.call!.participants.length,2);
 }finally{f.db.close();}
});
