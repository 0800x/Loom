import type { IncomingMessage,ServerResponse } from 'node:http';
import type { Duplex } from 'node:stream';
import { WebSocket,WebSocketServer } from 'ws';
import type { LoomNodeConfig } from '../config/config.ts';
import { GroupError } from '../groups/group_store.ts';
import { GroupCallService,type GroupCallAdmission } from './group_call_service.ts';
type Connection={admission:GroupCallAdmission;client:WebSocket;upstream:WebSocket;timer:NodeJS.Timeout};
/** SFU HTTP signaling must stay private. All client signaling enters here. */
export class GroupCallGateway {
  private server=new WebSocketServer({noServer:true,maxPayload:512*1024,perMessageDeflate:false});
  private calls:GroupCallService;private config:LoomNodeConfig;
  private connections=new Set<Connection>();private pending=0;private stopped=false;
  constructor(config:LoomNodeConfig,calls:GroupCallService){this.config=config;this.calls=calls;calls.onRevoke=(room,p)=>this.revoke(room,p);}
  private token(request:IncomingMessage,url:URL){const h=request.headers.authorization,t=h?.startsWith('Bearer ')?h.slice(7):url.searchParams.get('access_token');if(!t||t.length>8192)throw new GroupError(401,'invalid_group_call_token');return t;}
  private upstream(url:URL,ws:boolean){const target=new URL(url.pathname.endsWith('/validate')?'/rtc/validate':'/rtc',this.config.groupCalls!.apiUrl);if(ws)target.protocol=target.protocol==='https:'?'wss:':'ws:';target.search=url.search;target.searchParams.delete('access_token');return target;}
  async validate(request:IncomingMessage,response:ServerResponse){
    const url=new URL(request.url??'/','http://localhost');if(request.method!=='GET'||url.pathname!=='/conference/rtc/validate'){response.writeHead(404);response.end();return;}
    if(url.search.length>16384)throw new GroupError(400,'invalid_group_call_token');
    const admission=await this.calls.authorize(this.token(request,url));
    const result=await fetch(this.upstream(url,false),{method:'GET',redirect:'error',headers:{authorization:'Bearer '+admission.upstreamToken},signal:AbortSignal.timeout(5000)});
    const chunks:Uint8Array[]=[];let size=0;
    if(result.body){const reader=result.body.getReader();try{while(true){const next=await reader.read();if(next.done)break;size+=next.value.length;if(size>16384){await reader.cancel();throw new GroupError(503,'group_call_transport_unavailable');}chunks.push(next.value);}}finally{reader.releaseLock();}}
    if(!await this.calls.stillAuthorized(admission))throw new GroupError(403,'group_call_removed');
    response.writeHead(result.status,{'content-type':result.headers.get('content-type')??'text/plain'});response.end(Buffer.concat(chunks));
  }
  async upgrade(request:IncomingMessage,socket:Duplex,head:Buffer){
    let counted=false;
    try{
      const url=new URL(request.url??'/','http://localhost');
      if(this.stopped||!this.calls.enabled||url.pathname!=='/conference/rtc'||url.search.length>16384||this.pending>=64||this.connections.size>=512)throw new GroupError(503,'group_call_transport_unavailable');
      this.pending++;counted=true;const admission=await this.calls.authorize(this.token(request,url));if(socket.destroyed)return;
      const upstream=new WebSocket(this.upstream(url,true),{headers:{authorization:'Bearer '+admission.upstreamToken},handshakeTimeout:5000,maxPayload:512*1024,perMessageDeflate:false});
      let connection:Connection|undefined;const frames:{data:Buffer;binary:boolean}[]=[];let queued=0;
      const send=(target:WebSocket,data:Buffer|ArrayBuffer|Buffer[],binary:boolean)=>{
        if(target.readyState!==WebSocket.OPEN||target.bufferedAmount>1024*1024){if(connection)this.finish(connection);return;}
        target.send(data,{binary},error=>{if(error&&connection)this.finish(connection);});
      };
      // Retain JoinResponse while final authorization/client handshake runs.
      upstream.on('message',(data,binary)=>{if(connection){send(connection.client,data,binary);return;}const bytes=Array.isArray(data)?Buffer.concat(data):Buffer.from(data as ArrayBuffer);queued+=bytes.length;if(queued>1024*1024){upstream.terminate();socket.destroy();return;}frames.push({data:bytes,binary});});
      upstream.on('error',()=>{socket.destroy();if(connection)this.finish(connection);});
      upstream.on('close',()=>{if(connection)this.finish(connection);else socket.destroy();});
      upstream.once('open',()=>{void(async()=>{
        if(this.stopped||socket.destroyed||!await this.calls.stillAuthorized(admission)||upstream.readyState!==WebSocket.OPEN){upstream.terminate();socket.destroy();return;}
        this.server.handleUpgrade(request,socket,head,client=>{
          let checking=false;const timer=setInterval(async()=>{if(checking)return;checking=true;try{if(!await this.calls.stillAuthorized(admission)&&connection)this.finish(connection);}catch(_){if(connection)this.finish(connection);}finally{checking=false;}},3000);timer.unref();
          connection={admission,client,upstream,timer};this.connections.add(connection);let messages=0,window=Date.now();
          client.on('message',(data,binary)=>{if(Date.now()-window>=1000){window=Date.now();messages=0;}if(++messages>200){if(connection)this.finish(connection);return;}send(upstream,data,binary);});
          for(const frame of frames)send(client,frame.data,frame.binary);frames.length=0;queued=0;
          client.on('close',()=>{if(connection)this.finish(connection);});client.on('error',()=>{if(connection)this.finish(connection);});
        });
      })().catch(()=>{upstream.terminate();socket.destroy();if(connection)this.finish(connection);});});
      await new Promise<void>(resolve=>{upstream.once('open',resolve);upstream.once('error',resolve);upstream.once('close',resolve);});
    }catch(error){if(!socket.destroyed){const status=error instanceof GroupError?error.status:503;socket.end(`HTTP/1.1 ${status} Rejected\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`);}}finally{if(counted)this.pending--;}
  }
  private finish(c:Connection){if(!this.connections.delete(c))return;clearInterval(c.timer);c.client.close(4003,'Call authorization ended');c.upstream.close();const timer=setTimeout(()=>{c.client.terminate();c.upstream.terminate();},1000);timer.unref();}
  private revoke(room:string,p?:string){for(const c of this.connections)if(c.admission.room===room&&(!p||c.admission.participantId===p))this.finish(c);}
  close(){this.stopped=true;for(const c of this.connections)this.finish(c);this.server.close();}
}
