// Ephemeral integration fixture. All keys and tokens are generated for this test.
import { createHash, generateKeyPairSync, sign } from 'node:crypto';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { LoomNodeServer } from '../../src/bootstrap/server.ts';
import { SqliteStore, type RegistrationInput } from '../../src/storage/sqlite_store.ts';
import { DeviceBundleStore } from '../../src/security/device_bundle_store.ts';
import type { LoomNodeConfig } from '../../src/config/config.ts';
const adminToken='test-admin-token-012345678901234567890123456789';
function config(dir: string, registrationPolicy: 'open' | 'approval' | 'closed' = 'open'): LoomNodeConfig {
  return {
    schemaVersion: 1,
    mode: 'easy',
    listenHost: '127.0.0.1',
    listenPort: 0,
    publicDomain: 'localhost',
    publicBaseUrl: 'http://localhost',
    dataDirectory: dir,
    attachmentsDirectory: join(dir, 'attachments'),
    registrationPolicy,
    federationMode: 'disabled',
    networkJurisdiction: 'Test',
    operatorName: 'Test Node',
    adminToken,
    maxAttachmentBytes: 1024 * 1024,
    maxRequestBytes: 1024 * 1024,
  };
}

function rawPublicKey(pair: ReturnType<typeof generateKeyPairSync>): Buffer {
  const der = pair.publicKey.export({ type: 'spki', format: 'der' });
  return der.subarray(-32);
}

function fingerprint(bytes: Buffer): string {
  const hex = createHash('sha256').update(bytes).digest('hex').toUpperCase();
  return hex.match(/.{1,4}/g)!.join(' ');
}

function identityMaterial() {
  const pair = generateKeyPairSync('ed25519');
  const raw = rawPublicKey(pair);
  const digest = createHash('sha256').update(raw).digest();
  return {
    pair,
    public: {
      identityId: `chn:${digest.toString('base64url')}`,
      publicKey: raw.toString('base64'),
      fingerprint: fingerprint(raw),
    },
  };
}

function registrationBody(username: string, identity: ReturnType<typeof identityMaterial>): Record<string, unknown> {
  return {
    username,
    displayName: `Display ${username}`,
    password: 'correct horse battery staple',
    deviceName: 'Tests',
    identity: identity.public,
    protocolVersion: 'Loom-Identity-v1',
  };
}

function canonicalBundle(input: {
  identityId: string;
  deviceId: string;
  deviceName: string;
  signingPublicKey: string;
  agreementPublicKey: string;
  createdAt: string;
  capabilities: string[];
}): Buffer {
  return Buffer.from(JSON.stringify({
    bundleVersion: 1,
    identityId: input.identityId,
    deviceId: input.deviceId,
    deviceName: input.deviceName,
    signingPublicKey: input.signingPublicKey,
    agreementPublicKey: input.agreementPublicKey,
    createdAt: input.createdAt,
    capabilities: [...input.capabilities].sort(),
  }), 'utf8');
}

function deviceMaterial(identity: ReturnType<typeof identityMaterial>, deviceId: string) {
  const signingPair = generateKeyPairSync('ed25519');
  const agreementPair = generateKeyPairSync('x25519');
  const unsigned = {
    identityId: identity.public.identityId,
    deviceId,
    deviceName: 'Test Device',
    signingPublicKey: rawPublicKey(signingPair).toString('base64'),
    agreementPublicKey: rawPublicKey(agreementPair).toString('base64'),
    createdAt: new Date().toISOString(),
    capabilities: ['agreement-x25519', 'signing-ed25519'],
  };
  const canonical = canonicalBundle(unsigned);
  return {
    signingPair,
    bundle: {
      ...unsigned,
      bundleVersion: 1 as const,
      fingerprint: fingerprint(canonical),
      deviceSignature: sign(null, canonical, signingPair.privateKey).toString('base64'),
      identitySignature: sign(null, canonical, identity.pair.privateKey).toString('base64'),
    },
  };
}


const dir=mkdtempSync(join(tmpdir(),'loom-mls-http-'));
const store=new SqliteStore(dir),bundles=DeviceBundleStore.sqliteStore(dir);
const fixtures=[];
for(const name of ['alice','bob','carol']) {
  const identity=identityMaterial();
  const receipt=store.register(registrationBody(name,identity) as unknown as RegistrationInput,'localhost');
  const device=deviceMaterial(identity,receipt.deviceId);
  await bundles.publish(receipt.accountId,identity.public.identityId,receipt.deviceId,device.bundle);
  fixtures.push({receipt,bundle:device.bundle,identityPublicKey:identity.public.publicKey,
    signingSeed:device.signingPair.privateKey.export({type:'pkcs8',format:'der'}).subarray(-32).toString('base64')});
}
const server=new LoomNodeServer(config(dir),store,undefined,undefined,undefined,undefined,undefined,bundles);
const address=await server.listen();
process.stdout.write(JSON.stringify({baseUri:`http://127.0.0.1:${address.port}`,fixtures})+'\n');
process.stdin.resume();
let closed=false;
async function stop() {if(closed)return;closed=true;await server.close();rmSync(dir,{recursive:true,force:true});process.exit(0);}
process.stdin.on('data',()=>void stop());process.on('SIGTERM',()=>void stop());
