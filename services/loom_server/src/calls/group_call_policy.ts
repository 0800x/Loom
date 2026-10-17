import { randomUUID } from 'node:crypto';
import { GroupError, type GroupMember, type GroupState } from '../groups/group_store.ts';
export type GroupCallParticipant = {
  id:string; accountId:string; deviceId:string; identityId:string; name:string;
  state:'joining'|'connected'|'left'|'banned'; sid?:string; leaseUntil:number;
  granted:boolean; suspended:boolean; micBlocked:boolean; cameraBlocked:boolean;
  handRaisedAt?:number; lastRequestAt?:number;
};
export type GroupCallRecord = {
  id:string; groupId:string; room:string; epoch:number; revision:number;
  phase:'active'|'ended'; startedAt:number; endedAt?:number; kind:'audio'|'video';
  mode:'open'|'approval'; joinLocked:boolean; participants:GroupCallParticipant[]; transportClosed?:boolean;
};
export type GroupCallAuthority = {group:GroupState;actor?:GroupMember;activeDevices:ReadonlySet<string>;paused:boolean;call:GroupCallRecord|null};
export function callError(status:number,code:string):never {throw new GroupError(status,code);}
export function callMember(a:GroupCallAuthority,p:GroupCallParticipant) {
  return a.activeDevices.has(p.deviceId) ? a.group.members.find(m=>m.accountId===p.accountId&&m.deviceId===p.deviceId&&m.identityId===p.identityId) : undefined;
}
export function isCallAdmin(m?:GroupMember) {return !!m&&m.role!=='member';}
export function callPermission(a:GroupCallAuthority,p:GroupCallParticipant,now=Date.now()) {
  const m=callMember(a,p),c=a.call;
  const admitted=!!m&&!!c&&!a.paused&&c.phase==='active'&&c.epoch===a.group.epoch&&p.state==='connected'&&p.leaseUntil>now;
  const speak=admitted&&!p.suspended&&(c!.mode==='open'||isCallAdmin(m)||p.granted);
  return {subscribe:admitted,microphone:speak&&!p.micBlocked,camera:speak&&c!.kind==='video'&&!p.cameraBlocked};
}
export function refreshCallAuthority(a:GroupCallAuthority,now=Date.now()) {
  const c=a.call;if(!c||c.phase==='ended')return;
  if(c.epoch!==a.group.epoch||a.paused){c.phase='ended';c.endedAt=now;c.revision++;return;}
  for(const p of c.participants) if(['joining','connected'].includes(p.state)&&(!callMember(a,p)||p.leaseUntil<=now)) {p.state='left';p.handRaisedAt=undefined;c.revision++;}
  if(now-c.startedAt>120000&&!c.participants.some(p=>['joining','connected'].includes(p.state))) {c.phase='ended';c.endedAt=now;c.revision++;}
}
export function requireActiveCall(a:GroupCallAuthority,id:unknown) {
  const c=a.call;if(!c||c.phase!=='active'||c.id!==id)callError(409,'group_call_changed');return c;
}
export function startGroupCall(a:GroupCallAuthority,kind:unknown,mode:unknown,now=Date.now()) {
  if(!isCallAdmin(a.actor))callError(403,'group_call_admin_required');
  if(a.paused)callError(423,'group_paused');
  if(!['audio','video'].includes(String(kind))||!['open','approval'].includes(String(mode)))callError(400,'invalid_group_call');
  if(a.call?.phase==='active')callError(409,'group_call_exists');
  const id=randomUUID();a.call={id,groupId:a.group.id,room:'gc_'+id,epoch:a.group.epoch,revision:1,phase:'active',startedAt:now,kind:kind as 'audio'|'video',mode:mode as 'open'|'approval',joinLocked:false,participants:[]};return a.call;
}
export function joinGroupCall(a:GroupCallAuthority,id:unknown,name:string,maximum:number,now=Date.now()) {
  const c=requireActiveCall(a,id),m=a.actor;
  if(!m||!a.activeDevices.has(m.deviceId))callError(403,'group_call_member_required');
  let p=c.participants.find(p=>p.accountId===m.accountId);
  if(p?.state==='banned')callError(403,'group_call_removed');
  if(p&&p.deviceId!==m.deviceId&&['joining','connected'].includes(p.state))callError(409,'group_call_other_device');
  if(c.joinLocked&&!isCallAdmin(m)&&(!p||!['joining','connected'].includes(p.state)))callError(403,'group_call_join_locked');
  // Keep a seat for moderation while every admitted participant is ordinary.
  const admitted=c.participants.filter(p=>['joining','connected'].includes(p.state));
  const reserved=!isCallAdmin(m)&&!admitted.some(p=>isCallAdmin(callMember(a,p)));
  const limit=maximum-(reserved?1:0);
  if((!p||!['joining','connected'].includes(p.state))&&admitted.length>=limit)callError(409,'group_call_full');
  if(!p||p.state==='left'||p.deviceId!==m.deviceId){
    const previous=p;
    p={id:'p_'+randomUUID(),accountId:m.accountId,deviceId:m.deviceId,identityId:m.identityId,name:name.trim().slice(0,100),state:'joining',leaseUntil:now+60000,granted:previous?.granted??false,suspended:previous?.suspended??false,micBlocked:previous?.micBlocked??false,cameraBlocked:previous?.cameraBlocked??false};
    c.participants=c.participants.filter(x=>x.accountId!==m.accountId);c.participants.push(p);c.revision++;
  }else p.leaseUntil=now+60000;
  return p;
}
export function heartbeatGroupCall(a:GroupCallAuthority,id:unknown,now=Date.now()) {
  const c=requireActiveCall(a,id),p=c.participants.find(p=>p.accountId===a.actor?.accountId&&p.deviceId===a.actor?.deviceId);
  if(!p||!['joining','connected'].includes(p.state))callError(403,'group_call_removed');p.leaseUntil=now+15000;return p;
}
export function leaveGroupCall(a:GroupCallAuthority,id:unknown) {
  const c=requireActiveCall(a,id),p=c.participants.find(p=>p.accountId===a.actor?.accountId&&p.deviceId===a.actor?.deviceId);
  if(p&&['joining','connected'].includes(p.state)){p.state='left';p.handRaisedAt=undefined;c.revision++;}return p;
}
export function controlGroupCall(a:GroupCallAuthority,b:Record<string,unknown>,now=Date.now()) {
  const c=requireActiveCall(a,b.callId),m=a.actor;if(!m)callError(403,'group_call_member_required');
  if(b.action==='raise_hand'||b.action==='lower_hand'){
    const p=c.participants.find(p=>p.accountId===m.accountId&&p.deviceId===m.deviceId);
    if(!p||p.state!=='connected')callError(403,'group_call_member_required');
    if(b.action==='raise_hand'){
      if(p.handRaisedAt!=null)return;
      if(p.lastRequestAt!=null&&now-p.lastRequestAt<10000)callError(429,'group_call_request_rate_limited');
      p.handRaisedAt=now;p.lastRequestAt=now;
    }else p.handRaisedAt=undefined;
    c.revision++;return;
  }
  if(!isCallAdmin(m))callError(403,'group_call_admin_required');
  if(b.action==='end'){c.phase='ended';c.endedAt=now;c.revision++;return;}
  if(b.action==='set_mode'||b.action==='set_join_locked'){
    if(b.expectedRevision!==c.revision)callError(409,'group_call_changed');
    if(b.action==='set_mode'){
      if(!['open','approval'].includes(String(b.mode)))callError(400,'invalid_group_call_mode');
      c.mode=b.mode as 'open'|'approval';if(c.mode==='approval')for(const p of c.participants)p.granted=false;
    }else{
      if(typeof b.locked!=='boolean')callError(400,'invalid_group_call_lock');c.joinLocked=b.locked;
      if(c.joinLocked)for(const p of c.participants)if(p.state==='joining'&&!isCallAdmin(callMember(a,p)))p.state='left';
    }c.revision++;return;
  }
  const p=c.participants.find(p=>p.id===b.participantId),target=p&&callMember(a,p);
  if(!p||!target||!['joining','connected'].includes(p.state))callError(404,'group_call_participant_unavailable');
  if(p.accountId===m.accountId||(target.role!=='member'&&m.role!=='owner'))callError(403,'group_call_owner_required');
  switch(b.action){
    case 'allow_speak':p.granted=true;p.suspended=false;p.micBlocked=false;p.handRaisedAt=undefined;break;
    case 'deny_request':p.handRaisedAt=undefined;break;
    case 'mute':p.micBlocked=true;break;
    case 'revoke_speak':p.granted=false;p.suspended=true;p.handRaisedAt=undefined;break;
    case 'disable_camera':p.cameraBlocked=true;break;
    case 'allow_camera':p.cameraBlocked=false;break;
    case 'remove':p.state='banned';p.handRaisedAt=undefined;break;
    default:callError(400,'invalid_group_call_action');
  }c.revision++;
}
export function publicGroupCall(a:GroupCallAuthority,now=Date.now()) {
  const c=a.call;if(!c)return null;
  return {id:c.id,groupId:c.groupId,epoch:c.epoch,revision:c.revision,phase:c.phase,startedAt:c.startedAt,kind:c.kind,mode:c.mode,joinLocked:c.joinLocked,
    participants:c.participants.filter(p=>c.phase==='active'&&!!callMember(a,p)&&['joining','connected'].includes(p.state)).map(p=>({id:p.id,accountId:p.accountId,deviceId:p.deviceId,name:p.name,state:p.state,role:callMember(a,p)!.role,handRaisedAt:p.handRaisedAt,...callPermission(a,p,now)}))};
}
