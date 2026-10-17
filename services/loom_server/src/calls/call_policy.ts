import type { LoomNodeConfig } from '../config/config.ts';

// Applied to both local and federated offers; disabling video also disallows
// a camera-on upgrade from a voice call's signaling channel.
export function requireCallPolicy(config: LoomNodeConfig,
    signal: { kind: string; mediaKind?: 'audio' | 'video'; reason?: string }) {
  if (!config.callsEnabled) throw new Error('calls_disabled');
  if (signal.kind === 'call.offer' && signal.mediaKind === 'audio' && config.voiceCallsEnabled === false) {
    throw new Error('voice_calls_disabled');
  }
  if (config.videoCallsEnabled === false &&
      ((signal.kind === 'call.offer' && signal.mediaKind === 'video') ||
       (signal.kind === 'call.media' && signal.reason === 'camera-on'))) {
    throw new Error('video_calls_disabled');
  }
}
