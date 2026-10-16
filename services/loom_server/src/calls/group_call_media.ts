import { AccessToken, RoomServiceClient, TokenVerifier, TrackSource, WebhookReceiver } from 'livekit-server-sdk';
import type { LoomNodeConfig } from '../config/config.ts';
import type { GroupCallParticipant, GroupCallRecord } from './group_call_policy.ts';
export type MediaPermission={subscribe:boolean;microphone:boolean;camera:boolean};
export type MediaClaims={identity:string;room:string};
export type MediaEvent={id:string;event:string;room?:{name:string;sid?:string};participant?:{identity:string;sid:string}};
export interface GroupCallMedia {
  create(call:GroupCallRecord):Promise<void>; remove(room:string,participant:string):Promise<void>;
  close(room:string):Promise<void>; permission(room:string,participant:string,p:MediaPermission):Promise<void>;
  token(call:GroupCallRecord,p:GroupCallParticipant):Promise<string>; verify(token:string):Promise<MediaClaims>;
  webhook(body:string,authorization:string):Promise<MediaEvent>;
}
function absent(e:unknown){return typeof e==='object'&&e!==null&&'code' in e&&e.code==='not_found';}
export class LiveKitGroupCallMedia implements GroupCallMedia {
  private rooms:RoomServiceClient;private verifier:TokenVerifier;private receiver:WebhookReceiver;
  private settings:NonNullable<LoomNodeConfig['groupCalls']>;
  constructor(settings:NonNullable<LoomNodeConfig['groupCalls']>){
    this.settings=settings;this.rooms=new RoomServiceClient(settings.apiUrl,settings.apiKey,settings.apiSecret,{requestTimeout:5,failover:false});
    this.verifier=new TokenVerifier(settings.apiKey,settings.apiSecret);this.receiver=new WebhookReceiver(settings.apiKey,settings.apiSecret);
  }
  async create(c:GroupCallRecord){await this.rooms.createRoom({name:c.room,maxParticipants:this.settings.maxParticipants,emptyTimeout:120,departureTimeout:30});}
  async remove(room:string,p:string){try{await this.rooms.removeParticipant(room,p);}catch(e){if(!absent(e))throw e;}}
  async close(room:string){try{await this.rooms.deleteRoom(room);}catch(e){if(!absent(e))throw e;}}
  async permission(room:string,p:string,permission:MediaPermission){
    const sources=[permission.microphone?TrackSource.MICROPHONE:null,permission.camera?TrackSource.CAMERA:null].filter((s):s is TrackSource=>s!==null);
    await this.rooms.updateParticipant(room,p,{permission:{canSubscribe:permission.subscribe,canPublish:sources.length>0,canPublishSources:sources,canPublishData:false,canUpdateMetadata:false,hidden:false,recorder:false}});
  }
  async token(c:GroupCallRecord,p:GroupCallParticipant){
    // Even a refreshed SFU token enters the private gateway with zero grants.
    const token=new AccessToken(this.settings.apiKey,this.settings.apiSecret,{identity:p.id,name:p.name,ttl:60});
    token.addGrant({room:c.room,roomJoin:true,roomAdmin:false,canSubscribe:false,canPublish:false,canPublishData:false,canUpdateOwnMetadata:false,hidden:false,recorder:false});return token.toJwt();
  }
  async verify(token:string){const c=await this.verifier.verify(token,2);if(!c.sub||!c.video?.room||c.video.roomJoin!==true||c.video.roomAdmin)throw new Error('invalid_media_token');return {identity:c.sub,room:c.video.room};}
  async webhook(body:string,authorization:string){const e=await this.receiver.receive(body,authorization);return {id:e.id,event:e.event,room:e.room?{name:e.room.name,sid:e.room.sid}:undefined,participant:e.participant?{identity:e.participant.identity,sid:e.participant.sid}:undefined};}
}
