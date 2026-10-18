import { RateLimitError } from './rate_limiter.ts';
/** Never evict live security history in order to admit a new key. */
export class BoundedMap<K,V> extends Map<K,V> {
 private maximum:number;
 constructor(maximum:number){super();this.maximum=maximum;}
 override set(key:K,value:V):this {if(!this.has(key)&&this.size>=this.maximum)throw new RateLimitError(1);return super.set(key,value);}
}
