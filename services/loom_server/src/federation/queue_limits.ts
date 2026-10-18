import { RateLimitError } from '../security/rate_limiter.ts';
export type FederationQueueLimits={totalItems:number;peerItems:number;totalBytes:number;peerBytes:number};
export function queueLimits(env:NodeJS.ProcessEnv=process.env):FederationQueueLimits{
 const read=(name:string,fallback:number)=>{const n=Number(env[name]??fallback);if(!Number.isSafeInteger(n)||n<1)throw new Error('invalid_federation_queue_limit');return n;};
 return {totalItems:read('LOOM_FEDERATION_QUEUE_ITEMS',8192),peerItems:read('LOOM_FEDERATION_PEER_QUEUE_ITEMS',1024),totalBytes:read('LOOM_FEDERATION_QUEUE_BYTES',256*1024*1024),peerBytes:read('LOOM_FEDERATION_PEER_QUEUE_BYTES',64*1024*1024)};
}
export function requireQueueCapacity(stats:Record<string,unknown>,bytes:number,limits:FederationQueueLimits){
 if(Number(stats.total_items)>=limits.totalItems||Number(stats.peer_items)>=limits.peerItems||Number(stats.total_bytes)+bytes>limits.totalBytes||Number(stats.peer_bytes)+bytes>limits.peerBytes)throw new RateLimitError(60);
}
