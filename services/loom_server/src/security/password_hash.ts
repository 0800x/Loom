import { scrypt, timingSafeEqual } from 'node:crypto';
import { RateLimitError } from './rate_limiter.ts';
const CURRENT = { N: 131072, r: 8, p: 1, maxmem: 160 * 1024 * 1024 };
const LEGACY = { N: 16384, r: 8, p: 1, maxmem: 32 * 1024 * 1024 };

/** Bounded async worker-pool admission shared by every account/password store. */
export class PasswordHasher {
 private active=0;
 private waiting:Array<()=>void>=[];
 private concurrency:number;
 private queueLimit:number;
 constructor(concurrency=2,queueLimit=8){this.concurrency=concurrency;this.queueLimit=queueLimit;}
 private async derive(password:string,salt:Buffer,legacy=false):Promise<Buffer>{
  if(password.length>512||salt.length!==16)throw new Error('invalid_password_hash');
  if(this.active>=this.concurrency){
   if(this.waiting.length>=this.queueLimit)throw new RateLimitError(1);
   await new Promise<void>(resolve=>this.waiting.push(resolve));
  }else this.active++;
  try {return await new Promise<Buffer>((resolve,reject)=>scrypt(password,salt,32,legacy?LEGACY:CURRENT,(error,key)=>error?reject(error):resolve(key)));}
  finally {const next=this.waiting.shift();if(next)next();else this.active--;}
 }
 async hash(password:string,salt:Buffer):Promise<string>{const key=await this.derive(password,salt);try{return 'scrypt$131072$8$1$'+key.toString('base64');}finally{key.fill(0);}}
 async verify(password:string,salt:Buffer,encoded:string):Promise<{valid:boolean;legacy:boolean}>{
  const legacy=!encoded.startsWith('scrypt$');
  const raw=legacy?encoded:encoded.startsWith('scrypt$131072$8$1$')?encoded.slice('scrypt$131072$8$1$'.length):'';
  const expected=Buffer.from(raw,'base64');
  if(expected.length!==32||expected.toString('base64')!==raw)throw new Error('invalid_password_hash');
  const actual=await this.derive(password,salt,legacy);
  try{return {valid:timingSafeEqual(actual,expected),legacy};}finally{actual.fill(0);expected.fill(0);}
 }
}
export const passwordHasher = new PasswordHasher();
