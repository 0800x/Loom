import { createHmac } from 'node:crypto';

import type { LoomNodeConfig } from '../config/config.ts';
import type { SessionInfo } from '../storage/sqlite_store.ts';

export interface LoomRtcIceServer {
  urls: string[];
  username?: string;
  credential?: string;
}

export interface LoomRtcConfigResponse {
  iceServers: LoomRtcIceServer[];
  expiresAt: string;
}

export function rtcReady(config: LoomNodeConfig): boolean {
  if (!config.callsEnabled) return false;
  if (config.mode !== 'production') return true;
  return Boolean(
    config.rtcTurnUrls?.length &&
    config.rtcTurnSharedSecret &&
    config.rtcTurnSharedSecret.length >= 32,
  );
}

export function buildRtcConfiguration(
  config: LoomNodeConfig,
  session: SessionInfo,
  now = Date.now(),
): LoomRtcConfigResponse {
  if (!config.callsEnabled) throw new Error('calls_disabled');

  const ttlSeconds = config.rtcCredentialTtlSeconds ?? 600;
  const expiresAtMs = now + ttlSeconds * 1000;
  const iceServers: LoomRtcIceServer[] = [];

  if (config.rtcStunUrls?.length) {
    iceServers.push({ urls: [...config.rtcStunUrls] });
  }

  const turnUrls = config.rtcTurnUrls ?? [];
  if (turnUrls.length > 0) {
    const secret = config.rtcTurnSharedSecret;
    if (!secret) {
      // Easy Mode can intentionally run STUN-only for local development, but
      // configured TURN endpoints are never returned without authentication.
      throw new Error('turn_credentials_unavailable');
    }
    const expiryUnix = Math.ceil(expiresAtMs / 1000);
    // coturn's REST API authentication convention: expiration:user-id.
    const username = `${expiryUnix}:${session.identityId}:${session.deviceId}`;
    const credential = createHmac('sha1', secret).update(username).digest('base64');
    iceServers.push({ urls: [...turnUrls], username, credential });
  }

  if (config.mode === 'production' && !turnUrls.length) {
    throw new Error('turn_required');
  }

  return {
    iceServers,
    expiresAt: new Date(expiresAtMs).toISOString(),
  };
}
