import { createHash, createPublicKey, generateKeyPairSync, sign, verify } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';

export interface NodeIdentityPublic { nodeId: string; publicKey: string; fingerprint: string; }
interface PersistedIdentity { schemaVersion: 1; publicKeyPem: string; privateKeyPem: string; }
function base64UrlSha256(data: Buffer): string { return createHash('sha256').update(data).digest('base64url'); }
function fingerprint(data: Buffer): string { return createHash('sha256').update(data).digest('hex').toUpperCase().match(/.{1,4}/g)!.join(' '); }
function publicKeyFromRaw(raw: Buffer) { if (raw.length !== 32) throw new Error('invalid_node_public_key'); return createPublicKey({ key: Buffer.concat([Buffer.from('302a300506032b6570032100','hex'), raw]), format: 'der', type: 'spki' }); }

export class LoomNodeIdentity {
  private readonly publicKeyPem: string; private readonly privateKeyPem: string;
  private constructor(publicKeyPem:string,privateKeyPem:string){this.publicKeyPem=publicKeyPem;this.privateKeyPem=privateKeyPem;}
  static loadOrCreate(dataDirectory:string):LoomNodeIdentity{const path=resolve(dataDirectory,'node-identity.json');if(existsSync(path)){const parsed=JSON.parse(readFileSync(path,'utf8')) as PersistedIdentity;if(parsed.schemaVersion!==1||!parsed.publicKeyPem||!parsed.privateKeyPem)throw new Error('Invalid persisted Node identity');return new LoomNodeIdentity(parsed.publicKeyPem,parsed.privateKeyPem);}const pair=generateKeyPairSync('ed25519');const publicKeyPem=pair.publicKey.export({type:'spki',format:'pem'}).toString(),privateKeyPem=pair.privateKey.export({type:'pkcs8',format:'pem'}).toString();mkdirSync(dirname(path),{recursive:true});writeFileSync(path,JSON.stringify({schemaVersion:1,publicKeyPem,privateKeyPem} satisfies PersistedIdentity,null,2)+'\n',{mode:0o600});return new LoomNodeIdentity(publicKeyPem,privateKeyPem);}
  publicInfo():NodeIdentityPublic{const der=Buffer.from(requirePemBody(this.publicKeyPem),'base64'),raw=der.subarray(-32);return{nodeId:`node:${base64UrlSha256(raw)}`,publicKey:raw.toString('base64'),fingerprint:fingerprint(raw)};}
  signUtf8(value:string):string{return sign(null,Buffer.from(value,'utf8'),this.privateKeyPem).toString('base64');}
  verifyUtf8(value:string,signatureBase64:string):boolean{return verify(null,Buffer.from(value,'utf8'),this.publicKeyPem,Buffer.from(signatureBase64,'base64'));}
  static verifyUtf8(value:string,signatureBase64:string,publicKeyBase64:string):boolean{try{const raw=Buffer.from(publicKeyBase64,'base64');return verify(null,Buffer.from(value,'utf8'),publicKeyFromRaw(raw),Buffer.from(signatureBase64,'base64'));}catch{return false;}}
}
function requirePemBody(pem:string):string{const body=pem.split('\n').filter((line)=>line&&!line.startsWith('---')).join('');if(!body)throw new Error('Invalid PEM');return body;}
