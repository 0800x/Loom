import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { loadOrCreateConfig, validateConfig } from '../src/config/config.ts';

test('easy-mode configuration is created with safe defaults', () => {
  const dir = mkdtempSync(join(tmpdir(), 'loom-config-'));
  const path = join(dir, 'node.json');
  try {
    const loaded = loadOrCreateConfig(path);
    assert.equal(loaded.created, true);
    assert.equal(loaded.config.mode, 'easy');
    assert.equal(loaded.config.registrationPolicy, 'approval');
    assert.equal(loaded.config.federationMode, 'disabled');
    assert.ok(loaded.config.adminToken.length >= 32);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('public non-local HTTP URL is rejected', () => {
  const dir = mkdtempSync(join(tmpdir(), 'loom-config-'));
  try {
    const loaded = loadOrCreateConfig(join(dir, 'node.json'));
    assert.throws(() => validateConfig({ ...loaded.config, publicDomain: 'example.org', publicBaseUrl: 'http://example.org' }));
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('Easy Mode rejects private LAN cleartext', () => {
  const dir = mkdtempSync(join(tmpdir(), 'loom-config-'));
  try {
    const loaded = loadOrCreateConfig(join(dir, 'node.json'));
    assert.throws(() => validateConfig({
      ...loaded.config,
      listenHost: '0.0.0.0',
      publicDomain: '192.168.1.25:7483',
      publicBaseUrl: 'http://192.168.1.25:7483',
    }));
    assert.throws(() => validateConfig({
      ...loaded.config,
      mode: 'production',
      publicDomain: '192.168.1.25:7483',
      publicBaseUrl: 'http://192.168.1.25:7483',
    }));
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('federation is rejected on a cleartext Easy Mode endpoint', () => {
  const dir = mkdtempSync(join(tmpdir(), 'loom-config-'));
  try {
    const loaded = loadOrCreateConfig(join(dir, 'node.json'));
    assert.throws(() => validateConfig({
      ...loaded.config,
      publicDomain: '192.168.1.25:7483',
      publicBaseUrl: 'http://192.168.1.25:7483',
      federationMode: 'trusted',
    }));
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('configuration loader accepts a Windows UTF-8 BOM', () => {
  const dir = mkdtempSync(join(tmpdir(), 'loom-config-'));
  const path = join(dir, 'node.json');
  try {
    const initial = loadOrCreateConfig(path).config;
    writeFileSync(path, `\uFEFF${JSON.stringify(initial, null, 2)}\n`, 'utf8');
    const loaded = loadOrCreateConfig(path);
    assert.equal(loaded.created, false);
    assert.equal(loaded.config.publicDomain, initial.publicDomain);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});



test('runtime media limits override an existing config and reject invalid numbers', () => {
  const dir = mkdtempSync(join(tmpdir(), 'loom-limits-'));
  const path = join(dir, 'node.json');
  const previous = process.env.LOOM_MAX_ATTACHMENT_BYTES;
  try {
    const initial = loadOrCreateConfig(path).config;
    process.env.LOOM_MAX_ATTACHMENT_BYTES = '4194332';
    assert.equal(loadOrCreateConfig(path).config.maxAttachmentBytes, 4194332);
    for (const bad of [NaN, Infinity, 28, 1.5, 2 * 1024 ** 3 + 1]) {
      assert.throws(() => validateConfig({...initial, maxAttachmentBytes: bad}));
    }
  } finally { if (previous === undefined) delete process.env.LOOM_MAX_ATTACHMENT_BYTES; else process.env.LOOM_MAX_ATTACHMENT_BYTES = previous; rmSync(dir,{recursive:true,force:true}); }
});


test('calling setup environment overrides persisted JSON without changing unrelated identity', () => {
 const dir=mkdtempSync(join(tmpdir(),'loom-calling-runtime-')),path=join(dir,'node.json');
 const overrides:Record<string,string>={LOOM_CALLS_ENABLED:'true',LOOM_VOICE_CALLS_ENABLED:'true',LOOM_VIDEO_CALLS_ENABLED:'false',LOOM_GROUP_CALLS_ENABLED:'true',LOOM_GROUP_CALLS_API_URL:'http://livekit:7880',LOOM_GROUP_CALLS_API_KEY:'gc_test_key',LOOM_GROUP_CALLS_API_SECRET:'a'.repeat(64),LOOM_GROUP_CALLS_MAX_PARTICIPANTS:'24',LOOM_TURN_URLS:'turn:turn.example.org:3478',LOOM_STUN_URLS:'stun:turn.example.org:3478',LOOM_TURN_SHARED_SECRET:'t'.repeat(40)};
 const previous=new Map(Object.keys(overrides).map(k=>[k,process.env[k]]));
 try {
  const initial=loadOrCreateConfig(path).config;initial.callsEnabled=false;initial.voiceCallsEnabled=false;initial.videoCallsEnabled=true;writeFileSync(path,JSON.stringify(initial));
  Object.assign(process.env,overrides);const actual=loadOrCreateConfig(path).config;
  assert.equal(actual.callsEnabled,true);assert.equal(actual.voiceCallsEnabled,true);assert.equal(actual.videoCallsEnabled,false);
  assert.equal(actual.groupCalls?.enabled,true);assert.equal(actual.groupCalls?.maxParticipants,24);
  assert.deepEqual(actual.rtcTurnUrls,['turn:turn.example.org:3478']);assert.deepEqual(actual.rtcStunUrls,['stun:turn.example.org:3478']);assert.equal(actual.rtcTurnSharedSecret,'t'.repeat(40));
  assert.equal(actual.adminToken,initial.adminToken);assert.equal(actual.publicBaseUrl,initial.publicBaseUrl);
  process.env.LOOM_CALLS_ENABLED='false';process.env.LOOM_GROUP_CALLS_ENABLED='false';assert.equal(loadOrCreateConfig(path).config.callsEnabled,false);
 }finally{for(const [key,value] of previous){if(value===undefined)delete process.env[key];else process.env[key]=value;}rmSync(dir,{recursive:true,force:true});}
});
