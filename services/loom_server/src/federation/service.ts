import { createHash } from 'node:crypto';
import type { IncomingMessage } from 'node:http';
import type { LoomNodeConfig } from '../config/config.ts';
import { LoomNodeIdentity } from '../identity/node_identity.ts';
import { createHandshake } from './protocol.ts';
import { discoverRemoteNode } from './discovery.ts';
import { parseLoomAddress } from './address.ts';
import { FederationNodeRegistry, type FederationNodeRecord } from './node_registry.ts';
import { FederationRoutingStore, type RemoteUserProfile, type OutboxDelivery } from './routing_store.ts';
import { createFederationEnvelope, renewFederationEnvelope, validateFederationEnvelope, type FederationEnvelope, type FederationMessagePayload } from './event.ts';
import { verifyFederationUserProfile, type SignedFederationUserProfile } from './user_protocol.ts';
import { safeFederationHttpsRequest } from './safe_https.ts';
import { FederationDeliveryScheduler } from './delivery_scheduler.ts';

function privateAddress(value:string|undefined):boolean{if(!value)return false;const v=value.replace(/^::ffff:/,'').toLowerCase();if(v==='127.0.0.1'||v==='::1')return true;const m=/^(\d+)\.(\d+)\.(\d+)\.(\d+)$/.exec(v);if(m){const a=Number(m[1]),b=Number(m[2]);return a===10||a===127||(a===172&&b>=16&&b<=31)||(a===192&&b===168)||(a===169&&b===254);}return v.startsWith('fc')||v.startsWith('fd')||/^fe[89ab]/.test(v);}
function localEndpoint(peer:FederationNodeRecord):boolean{const host=new URL(peer.endpoint).hostname.toLowerCase();return host==='localhost'||host.endsWith('.local')||privateAddress(host);}
function permanentStatus(status:number){return[400,401,403,404,405,409,410,413,415,422,426].includes(status);}
function eventIdForMessage(messageId:unknown):string|undefined{const value=String(messageId??'');return /^msg_[0-9a-f-]{36}$/i.test(value)?`fevt_${value.slice(4)}`:undefined;}

export class FederationService{
  private readonly config:LoomNodeConfig;
  private readonly identity:LoomNodeIdentity;
  readonly nodes:FederationNodeRegistry;
  readonly routing:FederationRoutingStore;
  private worker?:NodeJS.Timeout;
  private readonly deliveries:FederationDeliveryScheduler;
  private lastWorkerError:string|null=null;
  private readonly discoveryTtlMs=15*60_000;
  private readonly discoveryHardTtlMs=7*24*60*60_000;

  constructor(config:LoomNodeConfig,identity:LoomNodeIdentity,nodes:FederationNodeRegistry,routing:FederationRoutingStore){
    this.config=config;this.identity=identity;this.nodes=nodes;this.routing=routing;
    this.deliveries=new FederationDeliveryScheduler(
      (limit,busyNodes)=>this.routing.dueDeliveries(limit,busyNodes),
      delivery=>this.deliverOne(delivery),
      error=>{this.lastWorkerError=(error instanceof Error?error.message:String(error)).slice(0,240);},
    );
  }
  start(){if(this.worker)return;this.deliveries.resume();this.worker=setInterval(()=>void this.deliverDue(),1000);this.worker.unref();void this.deliverDue();}
  stop(){this.deliveries.stop();if(this.worker){clearInterval(this.worker);this.worker=undefined;}}
  private allowPrivateDiscovery(){return this.config.federationMode==='local'||this.config.federationMode==='hybrid';}

  async discover(domain:string,force=false):Promise<FederationNodeRecord>{
    if(this.config.federationMode==='disabled')throw new Error('federation_disabled');
    const cached=await this.nodes.getByDomain(domain);
    if(cached?.trustState==='blocked')throw new Error('federation_node_blocked');
    if(!force&&cached&&Date.now()-Date.parse(cached.lastVerifiedAt)<this.discoveryTtlMs)return cached;
    try{
      const verified=await discoverRemoteNode(domain,{allowPrivate:this.allowPrivateDiscovery()});
      return await this.nodes.upsert(verified,cached?.trustState);
    }catch(error){
      if(cached)await this.nodes.noteFailure(cached.nodeId);
      throw error;
    }
  }

  private allowed(peer:FederationNodeRecord){
    const mode=this.config.federationMode;
    if(mode==='disabled'||peer.trustState==='blocked')return false;
    if(mode==='open')return true;
    if(mode==='trusted')return peer.trustState==='trusted';
    if(mode==='local')return localEndpoint(peer);
    if(mode==='hybrid')return peer.trustState==='trusted'||localEndpoint(peer);
    return false;
  }

  /// Resolve a peer for an inbound signed request without turning a transient
  /// reverse-path outage into an inbound outage. A recently cryptographically
  /// verified binding is authoritative until the hard TTL. Soft-stale bindings
  /// are refreshed asynchronously. Unknown peers and any claimed key/endpoint
  /// change still require live discovery and therefore fail closed.
  async peerForInbound(input:{domain:string;nodeId:string;publicKey?:string;endpoint?:string}):Promise<FederationNodeRecord>{
    if(this.config.federationMode==='disabled')throw new Error('federation_disabled');
    let peer=await this.nodes.getByDomain(input.domain);
    const matches=(candidate:FederationNodeRecord)=>candidate.nodeId===input.nodeId&&
      (input.publicKey==null||candidate.publicKey===input.publicKey)&&
      (input.endpoint==null||candidate.endpoint===input.endpoint);

    if(!peer){
      peer=await this.discover(input.domain,true);
    }else{
      const age=Date.now()-Date.parse(peer.lastVerifiedAt);
      if(!Number.isFinite(age)||age<0||age>=this.discoveryHardTtlMs||!matches(peer)){
        peer=await this.discover(input.domain,true);
      }else if(age>=this.discoveryTtlMs){
        void this.discover(input.domain,true).catch(()=>{});
      }
    }

    if(!matches(peer))throw new Error('federation_node_id_mismatch');
    if(!this.allowed(peer))throw new Error('federation_peer_not_allowed');
    return peer;
  }

  async resolveUser(addressValue:string,forceProfileRefresh=false):Promise<RemoteUserProfile>{
    const address=parseLoomAddress(addressValue,this.config.publicDomain);
    if(address.isLocal){
      const profile=await this.routing.resolveLocalUser(address.username,address.domain);
      if(!profile)throw new Error('user_not_found');
      profile.homeNode.nodeId=this.identity.publicInfo().nodeId;
      return profile;
    }
    const peer=await this.discover(address.domain);
    if(!this.allowed(peer))throw new Error('federation_peer_not_trusted');
    const cached=await this.routing.getCachedRemoteUser(address.canonical);
    if(!forceProfileRefresh&&cached&&cached.homeNode.nodeId===peer.nodeId)return cached;
    const handshake=createHandshake(this.identity,this.config.publicDomain,this.config.publicBaseUrl);
    const started=Date.now();
    try{
      const response=await safeFederationHttpsRequest(`${peer.endpoint}/federation/v1/users/resolve`,{
        method:'POST',
        headers:{'content-type':'application/json',accept:'application/json'},
        body:JSON.stringify({handshake,address:address.canonical}),
        timeoutMs:8000,
        maxBytes:768*1024,
        allowPrivate:this.allowPrivateDiscovery(),
      });
      if(response.status===404)throw new Error('user_not_found');
      if(response.status<200||response.status>=300)throw new Error(`federation_user_lookup_http_${response.status}`);
      let signed:SignedFederationUserProfile;
      try{signed=JSON.parse(response.body.toString('utf8')) as SignedFederationUserProfile;}catch{throw new Error('invalid_federation_user_json');}
      const profile=verifyFederationUserProfile(signed,peer.publicKey,{address:address.canonical,nodeId:peer.nodeId,domain:peer.domain});
      await this.routing.cacheRemoteUser(profile);
      await this.nodes.noteSuccess(peer.nodeId,Date.now()-started);
      return profile;
    }catch(error){
      await this.nodes.noteFailure(peer.nodeId);
      throw error;
    }
  }

  /// Creates a one-to-one conversation endpoint for either a local or remote
  /// Loom address. Local peers deliberately use the same opaque remote-member
  /// representation so each account gets its own Node-local conversation row;
  /// the E2EE layer binds to long-term participant identities, not these row IDs.
  async createRemoteConversation(accountId:string,addressValue:string){
    const address=parseLoomAddress(addressValue,this.config.publicDomain);
    const profile=await this.resolveUser(address.canonical,true);
    const conversationId=await this.routing.ensureRemoteConversation(accountId,address.canonical,profile.homeNode.nodeId);
    return{conversationId,peerAddress:address.canonical,profile};
  }

  async routeLocalMessage(input:{conversationId:string;senderAddress:string;receipt:Record<string,unknown>;message:FederationMessagePayload}){
    const members=await this.routing.remoteMembers(input.conversationId),results:Array<Record<string,unknown>>=[];
    const self=this.identity.publicInfo();
    const sourceMessageId=String(input.receipt.messageId??'');
    for(const member of members){
      const parsed=parseLoomAddress(member.address,this.config.publicDomain);

      // Same-Node direct delivery never leaves the process and does not depend
      // on federation being enabled. It still uses a signed, idempotent opaque
      // envelope and the normal inbound storage/sync path; no plaintext or
      // client key is exposed to the Node.
      if(member.nodeId===self.nodeId&&parsed.isLocal){
        const envelope=createFederationEnvelope(this.identity,{
          eventId:eventIdForMessage(sourceMessageId),
          eventType:'message.created',
          originDomain:this.config.publicDomain,
          destinationNodeId:self.nodeId,
          destinationDomain:this.config.publicDomain,
          senderAddress:input.senderAddress,
          recipientAddresses:[member.address],
          conversationId:input.conversationId,
          createdAt:new Date().toISOString(),
          payload:{...input.message,createdAt:input.message.createdAt??String(input.receipt.createdAt)},
        });
        validateFederationEnvelope(envelope,self.publicKey,{
          localDomain:this.config.publicDomain,
          localNodeId:self.nodeId,
          maxCiphertextBytes:this.config.maxRequestBytes,
        });
        await this.routing.applyInbound(envelope);
        await this.routing.markLocalDelivered(sourceMessageId,this.config.publicDomain);
        continue;
      }

      let peer=await this.nodes.get(member.nodeId);
      if(!peer){
        peer=await this.discover(parsed.domain);
      }else{
        const age=Date.now()-Date.parse(peer.lastVerifiedAt);
        if(!Number.isFinite(age)||age<0||age>=this.discoveryHardTtlMs){
          peer=await this.discover(parsed.domain,true);
        }else if(age>=this.discoveryTtlMs){
          // Refresh a still-valid verified binding without putting a discovery
          // round trip on every outgoing message. Hard expiry still fails closed.
          void this.discover(parsed.domain,true).catch(()=>{});
        }
      }
      if(peer.nodeId!==member.nodeId)throw new Error('federation_remote_node_identity_changed');
      if(!this.allowed(peer))throw new Error('federation_peer_not_trusted');
      const envelope=createFederationEnvelope(this.identity,{
        eventId:eventIdForMessage(sourceMessageId),
        eventType:'message.created',
        originDomain:this.config.publicDomain,
        destinationNodeId:peer.nodeId,
        destinationDomain:peer.domain,
        senderAddress:input.senderAddress,
        recipientAddresses:[member.address],
        conversationId:input.conversationId,
        createdAt:new Date().toISOString(),
        payload:{...input.message,createdAt:input.message.createdAt??String(input.receipt.createdAt)},
      });
      const delivery=await this.routing.enqueue(envelope,peer.endpoint,sourceMessageId);
      results.push({deliveryId:delivery.deliveryId,eventId:delivery.eventId,destinationDomain:delivery.destinationDomain,status:delivery.status});
    }
    if(results.length>0)void this.deliverDue();
    return results;
  }

  async acknowledgeReceived(accountId:string, ownAddress:string, clientIds:string[]):Promise<void>{
    if(this.config.federationMode==='disabled')return;
    const targets=await this.routing.incomingReceiptTargets(accountId,ownAddress,clientIds);
    for(const target of targets){
      const domain=parseLoomAddress(target.senderAddress).domain;
      if(domain===this.config.publicDomain.toLowerCase())continue;
      const peer=await this.peerForInbound({domain,nodeId:target.nodeId});
      const hash=createHash('sha256').update(`recipient-receipt:${target.eventId}:${ownAddress.toLowerCase()}`).digest('hex').slice(0,32);
      const eventId=`fevt_${hash.slice(0,8)}-${hash.slice(8,12)}-${hash.slice(12,16)}-${hash.slice(16,20)}-${hash.slice(20)}`;
      const envelope=createFederationEnvelope(this.identity,{
        eventId,eventType:'message.received',originDomain:this.config.publicDomain,
        destinationNodeId:peer.nodeId,destinationDomain:peer.domain,
        senderAddress:ownAddress,recipientAddresses:[target.senderAddress],
        conversationId:target.conversationId,createdAt:new Date().toISOString(),
        payload:{messageId:target.eventId,clientId:target.clientId,type:'RECEIPT',ciphertext:'',protocolVersion:'Loom-Receipt-v1'},
      });
      await this.routing.enqueue(envelope,peer.endpoint);
    }
    if(targets.length>0)void this.deliverDue();
  }

  async acceptInbound(envelope:FederationEnvelope,_request:IncomingMessage){
    const origin=parseLoomAddress(envelope.senderAddress);
    if(origin.domain!==String(envelope.originDomain).toLowerCase())throw new Error('federation_sender_origin_mismatch');
    const peer=await this.peerForInbound({domain:origin.domain,nodeId:envelope.originNodeId});
    try{
      validateFederationEnvelope(envelope,peer.publicKey,{localDomain:this.config.publicDomain,localNodeId:this.identity.publicInfo().nodeId,maxCiphertextBytes:this.config.maxRequestBytes});
    }catch(error){
      if(error instanceof Error&&error.message.includes('signature'))await this.routing.noteMetric('signature_failures');
      throw error;
    }
    const result=await this.routing.applyInbound(envelope);
    await this.nodes.noteSuccess(peer.nodeId);
    return result;
  }

  async deliverDue(){
    if(this.config.federationMode==='disabled')return;
    try{
      await this.deliveries.kick();
    }catch(error){
      this.lastWorkerError=(error instanceof Error?error.message:String(error)).slice(0,240);
    }
  }

  private async deliverOne(delivery:OutboxDelivery){
    const attempts=delivery.attempts+1,peer=await this.nodes.get(delivery.destinationNodeId);
    if(!peer||peer.trustState==='blocked'||!this.allowed(peer)){
      await this.routing.markFailed(delivery.deliveryId,attempts,'federation_destination_not_allowed');
      return;
    }
    const started=Date.now();
    try{
      // Resolve the current verified endpoint at send time. Queued rows keep the
      // endpoint for diagnostics/history, but retries must not be pinned forever
      // to an endpoint that the same verified NodeId has legitimately changed.
      const response=await safeFederationHttpsRequest(`${peer.endpoint}/federation/v1/events`,{
        method:'POST',
        headers:{'content-type':'application/json',accept:'application/json'},
        body:JSON.stringify(renewFederationEnvelope(this.identity,JSON.parse(delivery.payload) as FederationEnvelope)),
        timeoutMs:10_000,
        maxBytes:64*1024,
        allowPrivate:this.allowPrivateDiscovery(),
      });
      if(response.status>=200&&response.status<300){
        await this.routing.markDelivered(delivery.deliveryId);
        await this.nodes.noteSuccess(peer.nodeId,Date.now()-started);
        return;
      }
      const error=`federation_delivery_http_${response.status}`;
      if(permanentStatus(response.status)||attempts>=8){
        await this.routing.markFailed(delivery.deliveryId,attempts,error);
        await this.nodes.noteFailure(peer.nodeId);
        return;
      }
      await this.retry(delivery,attempts,error);
    }catch(error){
      const message=error instanceof Error?error.message:String(error);
      if(attempts>=8)await this.routing.markFailed(delivery.deliveryId,attempts,message);
      else await this.retry(delivery,attempts,message);
      await this.nodes.noteFailure(peer.nodeId);
    }
  }

  private async retry(delivery:OutboxDelivery,attempts:number,error:string){
    const base=Math.min(5*60_000,2000*(2**Math.min(attempts-1,8))),jitter=Math.floor(Math.random()*Math.max(250,base*0.25));
    await this.routing.markRetry(delivery.deliveryId,attempts,new Date(Date.now()+base+jitter),error);
  }

  async diagnostics(){
    const nodes=await this.nodes.list(),routing=await this.routing.diagnostics(),queue=routing.queue as Record<string,number>,counters=routing.counters as Record<string,number>;
    return{
      mode:this.config.federationMode,
      enabled:this.config.federationMode!=='disabled',
      inFlightDeliveries:this.deliveries.inFlight,
      lastWorkerError:this.lastWorkerError,
      discoveredNodes:nodes.length,
      trustedNodes:nodes.filter(n=>n.trustState==='trusted').length,
      blockedNodes:nodes.filter(n=>n.trustState==='blocked').length,
      healthyNodes:nodes.filter(n=>n.lastSuccessfulContactAt&&(!n.lastFailureAt||Date.parse(n.lastSuccessfulContactAt)>=Date.parse(n.lastFailureAt))).length,
      unreachableNodes:nodes.filter(n=>n.failureCount>0).length,
      pendingOutboundDeliveries:queue.pending??0,
      retryingDeliveries:queue.retrying??0,
      failedDeliveries:queue.failed??0,
      deliveredEventsTotal:counters.delivered_events_total??0,
      receivedEventsTotal:counters.received_events_total??0,
      duplicateEventsRejected:counters.duplicate_events_rejected??0,
      signatureFailures:counters.signature_failures??0,
      lastFederationSuccess:nodes.map(n=>n.lastSuccessfulContactAt).filter(Boolean).sort().at(-1)??null,
      lastFederationError:nodes.map(n=>n.lastFailureAt).filter(Boolean).sort().at(-1)??null,
      nodes:nodes.map(n=>({domain:n.domain,nodeId:n.nodeId,fingerprint:n.fingerprint,trustState:n.trustState,health:n.trustState==='blocked'?'blocked':n.failureCount>0?'degraded':n.lastSuccessfulContactAt?'online':'unknown',lastVerification:n.lastVerifiedAt,lastContact:n.lastSuccessfulContactAt,latencyMs:n.latencyMs,recentFailures:n.failureCount})),
    };
  }
}
