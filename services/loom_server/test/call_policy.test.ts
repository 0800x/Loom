import test from 'node:test';
import assert from 'node:assert/strict';
import { requireCallPolicy } from '../src/calls/call_policy.ts';
import { createDefaultConfig } from '../src/config/config.ts';

test('operator policies reject disabled offers and video upgrades, permit call teardown', () => {
  const config={...createDefaultConfig(),callsEnabled:true,voiceCallsEnabled:true,videoCallsEnabled:false};
  assert.doesNotThrow(()=>requireCallPolicy(config,{kind:'call.offer',mediaKind:'audio'}));
  for (const signal of [{kind:'call.offer',mediaKind:'video' as const},{kind:'call.media',reason:'camera-on'}]) {
    assert.throws(()=>requireCallPolicy(config,signal),/video_calls_disabled/);
  }
  assert.doesNotThrow(()=>requireCallPolicy(config,{kind:'call.end'}));
  assert.throws(()=>requireCallPolicy({...config,voiceCallsEnabled:false},{kind:'call.offer',mediaKind:'audio'}),/voice_calls_disabled/);
  assert.throws(()=>requireCallPolicy({...config,callsEnabled:false},{kind:'call.offer',mediaKind:'audio'}),/calls_disabled/);
});
