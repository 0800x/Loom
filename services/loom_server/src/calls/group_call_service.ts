import type { LoomNodeConfig } from '../config/config.ts';
import type { SessionInfo } from '../storage/sqlite_store.ts';
import { GroupStore } from '../groups/group_store.ts';
import { LiveKitGroupCallMedia, type GroupCallMedia } from './group_call_media.ts';
import {callError,callMember,callPermission,controlGroupCall,heartbeatGroupCall,joinGroupCall,leaveGroupCall,publicGroupCall,refreshCallAuthority,requireActiveCall,startGroupCall,type GroupCallAuthority} from './group_call_policy.ts';
export type GroupCallAdmission={groupId:string;callId:string;participantId:string;room:string;upstreamToken:string};
export class GroupCallService {
  readonly enabled:boolean;readonly media?:GroupCallMedia;
  private config:LoomNodeConfig;private groups:GroupStore;private clock:()=>number;
  private queues=new Map<string,Promise<void>>();private applied=new Map<string,string>();
  private eventIds=new Map<string,number>();private timer?:NodeJS.Timeout;private stopped=false;private ticking=false;
  onRevoke?:(room:string,participant?:string)=>void;
  constructor(config:LoomNodeConfig,groups:GroupStore,options:{media?:GroupCallMedia;clock?:()=>number;timers?:boolean}={}){
    this.config=config;this.groups=groups;this.clock=options.clock??Date.now;
    this.enabled=config.callsEnabled===true&&config.voiceCallsEnabled!==false&&config.groupCalls?.enabled===true;
    this.media=this.enabled?options.media??new LiveKitGroupCallMedia(config.groupCalls!):undefined;
    if(this.enabled&&options.timers!==false){this.timer=setInterval(()=>void this.tick(),3000);this.timer.unref();}
  }
  stop(){this.stopped=true;if(this.timer)clearInterval(this.timer);}
  async close(){this.stop();await Promise.all([...this.queues.values()]);}
  private serial<T>(id:string,action:()=>Promise<T>):Promise<T>{
    const result=(this.queues.get(id)??Promise.resolve()).then(action),done=result.then(()=>{},()=>{});
    this.queues.set(id,done);void done.then(()=>{if(this.queues.get(id)===done)this.queues.delete(id);});return result;
  }
  private authority(id:string,session?:SessionInfo):Promise<GroupCallAuthority>{return this.groups.withGroupCall(id,session,a=>{refreshCallAuthority(a,this.clock());return a;});}
  private available(){if(!this.media||this.stopped)callError(503,'group_calls_not_configured');}
  async view(session:SessionInfo,id:string){
    if(!this.enabled){await this.groups.get(session,id);return {available:false,call:null};}
    return this.serial(id,async()=>{await this.reconcile(id).catch(()=>{});const a=await this.authority(id,session);return {available:true,video:this.config.videoCallsEnabled!==false,maximum:this.config.groupCalls!.maxParticipants,call:publicGroupCall(a,this.clock())};});
  }
  async start(session:SessionInfo,id:string,body:Record<string,unknown>){
    this.available();if(body.kind==='video'&&this.config.videoCallsEnabled===false)callError(403,'video_calls_disabled');
    return this.serial(id,async()=>{
      const previous=await this.authority(id,session);if(previous.call?.phase==='ended'&&!previous.call.transportClosed)await this.reconcile(id);
      const call=await this.groups.withGroupCall(id,session,a=>{refreshCallAuthority(a,this.clock());return startGroupCall(a,body.kind,body.mode,this.clock());});
      try{await this.media!.create(call);}catch(_){await this.groups.withGroupCall(id,undefined,a=>{if(a.call?.id===call.id){a.call.phase='ended';a.call.endedAt=this.clock();}});callError(503,'group_call_transport_unavailable');}
      const a=await this.authority(id,session);if(a.call?.phase!=='active'||a.call.id!==call.id){await this.reconcile(id);callError(409,'group_call_changed');}
      return {available:true,call:publicGroupCall(a,this.clock())};
    });
  }
  async join(session:SessionInfo,id:string,body:Record<string,unknown>){
    this.available();return this.serial(id,async()=>{
      const profile=await this.groups.memberProfile(session,session.deviceId);
      const joined=await this.groups.withGroupCall(id,session,a=>{refreshCallAuthority(a,this.clock());const participant=joinGroupCall(a,body.callId,profile.displayName||profile.username,this.config.groupCalls!.maxParticipants,this.clock());return {call:a.call!,participant};});
      const token=await this.media!.token(joined.call,joined.participant),a=await this.authority(id,session);requireActiveCall(a,joined.call.id);
      return {participantId:joined.participant.id,token,url:this.config.publicBaseUrl.replace(/^http/,'ws').replace(/\/$/,'')+'/conference',call:publicGroupCall(a,this.clock())};
    });
  }
  async heartbeat(session:SessionInfo,id:string,body:Record<string,unknown>){this.available();return this.groups.withGroupCall(id,session,a=>{refreshCallAuthority(a,this.clock());heartbeatGroupCall(a,body.callId,this.clock());return {call:publicGroupCall(a,this.clock())};});}
  async leave(session:SessionInfo,id:string,body:Record<string,unknown>){
    this.available();return this.serial(id,async()=>{const a=await this.groups.withGroupCall(id,session,a=>{refreshCallAuthority(a,this.clock());leaveGroupCall(a,body.callId);return a;});await this.reconcile(id).catch(()=>{});return {call:publicGroupCall(a,this.clock())};});
  }
  async control(session:SessionInfo,id:string,body:Record<string,unknown>){
    this.available();return this.serial(id,async()=>{const a=await this.groups.withGroupCall(id,session,a=>{refreshCallAuthority(a,this.clock());controlGroupCall(a,body,this.clock());return a;});try{await this.reconcile(id);}catch(_){callError(503,'group_call_transport_unavailable');}return {call:publicGroupCall(a,this.clock())};});
  }
  async authorize(token:string):Promise<GroupCallAdmission>{
    this.available();let claims;try{claims=await this.media!.verify(token);}catch(_){callError(401,'invalid_group_call_token');}
    const id=await this.groups.groupCallIdForRoom(claims.room);if(!id)callError(403,'group_call_removed');
    const a=await this.authority(id),c=a.call,p=c?.participants.find(p=>p.id===claims.identity);
    if(!c||c.room!==claims.room||c.phase!=='active'||!p||!['joining','connected'].includes(p.state)||!callMember(a,p)||p.leaseUntil<=this.clock())callError(403,'group_call_removed');
    // A refreshed JWT's former publish grants must never reach the SFU.
    const upstreamToken=await this.media!.token(c,p);return {groupId:id,callId:c.id,room:c.room,participantId:p.id,upstreamToken};
  }
  async stillAuthorized(admission:GroupCallAdmission){
    if(this.stopped)return false;
    try{const a=await this.authority(admission.groupId),c=a.call,p=c?.participants.find(p=>p.id===admission.participantId);return !!c&&c.id===admission.callId&&c.phase==='active'&&!!p&&['joining','connected'].includes(p.state)&&!!callMember(a,p)&&p.leaseUntil>this.clock();}catch(_){return false;}
  }
  async webhook(body:string,authorization:string){
    this.available();let event;try{event=await this.media!.webhook(body,authorization);}catch(_){callError(401,'invalid_group_call_webhook');}
    if(!event.id||event.id.length>128||!event.room)return;
    const now=this.clock();for(const [id,expiry] of this.eventIds)if(expiry<=now)this.eventIds.delete(id);
    if(this.eventIds.has(event.id))return;
    const id=await this.groups.groupCallIdForRoom(event.room.name);if(!id)return;
    await this.serial(id,async()=>{
      if(this.eventIds.has(event.id))return;let rejected:string|undefined;
      await this.groups.withGroupCall(id,undefined,a=>{
        refreshCallAuthority(a,now);const c=a.call;if(!c||c.room!==event.room!.name)return;
        if(event.event==='room_finished'){c.phase='ended';c.endedAt=now;c.transportClosed=true;return;}
        const identity=event.participant?.identity,sid=event.participant?.sid;if(!identity||!sid)return;
        const p=c.participants.find(p=>p.id===identity);
        if(event.event==='participant_joined'){
          if(c.phase!=='active'||!p||!callMember(a,p)||!['joining','connected'].includes(p.state)||p.leaseUntil<=now){rejected=identity;return;}
          p.state='connected';p.sid=sid;p.leaseUntil=now+15000;c.revision++;
        }else if(['participant_left','participant_connection_aborted'].includes(event.event)&&p?.sid===sid){
          p.sid=undefined;if(p.state==='connected'){p.state='joining';p.leaseUntil=now+15000;c.revision++;}
        }
      });
      if(rejected){this.onRevoke?.(event.room!.name,rejected);await this.media!.remove(event.room!.name,rejected);}
      await this.reconcile(id);if(this.eventIds.size>=4096)this.eventIds.delete(this.eventIds.keys().next().value!);this.eventIds.set(event.id,now+120000);
    });
  }
  async membershipChanged(id:string){if(this.enabled)await this.serial(id,()=>this.reconcile(id)).catch(()=>{});}
  private async reconcile(id:string){
    const a=await this.authority(id),c=a.call;if(!c||!this.media)return;
    if(c.phase==='ended'){
      this.onRevoke?.(c.room);if(!c.transportClosed){await this.media.close(c.room);await this.groups.withGroupCall(id,undefined,a=>{if(a.call?.id===c.id&&a.call.phase==='ended')a.call.transportClosed=true;});}
      for(const key of this.applied.keys())if(key.startsWith(c.room+':'))this.applied.delete(key);return;
    }
    for(const p of c.participants){
      if(this.stopped)return;const key=c.room+':'+p.id;
      if(!['joining','connected'].includes(p.state)||!callMember(a,p)){
        this.onRevoke?.(c.room,p.id);if(this.applied.get(key)!=='removed'){await this.media.remove(c.room,p.id);this.applied.set(key,'removed');}
      }else if(p.state==='connected'&&p.sid){const permission=callPermission(a,p,this.clock()),signature=p.sid+JSON.stringify(permission);if(this.applied.get(key)!==signature){await this.media.permission(c.room,p.id,permission);this.applied.set(key,signature);}}
    }
    // A concurrent MLS commit must not be undone by a delayed SFU response.
    const fresh=await this.authority(id);if(fresh.call?.id!==c.id||fresh.call.phase!=='active'){this.onRevoke?.(c.room);await this.media.close(c.room);}
  }
  private async tick(){
    if(this.ticking||this.stopped)return;this.ticking=true;
    try{const ids=await this.groups.activeGroupCallIds();let next=0;const worker=async()=>{while(!this.stopped&&next<ids.length){const id=ids[next++];await this.serial(id,()=>this.reconcile(id)).catch(()=>{});}};await Promise.all(Array.from({length:4},worker));}catch(_){/* gateway and client watchdog fail closed */}finally{this.ticking=false;}
  }
}
