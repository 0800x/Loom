import { createHash } from 'node:crypto';
import type { IncomingMessage } from 'node:http';
import type { SessionInfo } from '../storage/sqlite_store.ts';
import type { DeviceBundleStore } from './device_bundle_store.ts';
import { verifyRawEd25519 } from '../identity/public_material.ts';

export const EMPTY_BODY_SHA256 = createHash('sha256').update(Buffer.alloc(0)).digest('hex');

export interface VerifiedDeviceRequest {
  deviceId: string;
  bodySha256: string;
  timestampMs: number;
  nonce: string;
  bootstrap: boolean;
}

function singleHeader(request: IncomingMessage, name: string): string {
  const value = request.headers[name];
  if (typeof value !== 'string') throw new Error('device_request_proof_required');
  const cleaned = value.trim();
  if (!cleaned || cleaned.length > 2048 || /[\r\n]/.test(cleaned)) throw new Error('invalid_device_request_proof');
  return cleaned;
}

function targetFor(request: IncomingMessage): string {
  const target = request.url ?? '/';
  if (!target.startsWith('/') || target.length > 4096 || /[\r\n#]/.test(target)) throw new Error('invalid_device_request_target');
  return target;
}

function bootstrapBundlePath(request: IncomingMessage, session: SessionInfo): boolean {
  if ((request.method ?? '').toUpperCase() !== 'PUT') return false;
  const match = /^\/api\/v1\/devices\/([^/?]+)\/key-bundle(?:\?.*)?$/.exec(request.url ?? '');
  if (!match) return false;
  try {
    return decodeURIComponent(match[1]) === session.deviceId;
  } catch {
    return false;
  }
}

export function sha256Hex(value: Buffer | string): string {
  return createHash('sha256').update(value).digest('hex');
}

export function canonicalDeviceRequestProof(input: {
  method: string;
  target: string;
  bodySha256: string;
  timestampMs: number | string;
  nonce: string;
  deviceId: string;
  credentialSha256: string;
}): string {
  return [
    'Loom-Device-Request-v1',
    input.method.toUpperCase(),
    input.target,
    input.bodySha256.toLowerCase(),
    String(input.timestampMs),
    input.nonce,
    input.deviceId,
    input.credentialSha256.toLowerCase(),
  ].join('\n');
}

export class DeviceRequestVerifier {
  private readonly bundles: DeviceBundleStore;

  constructor(bundles: DeviceBundleStore) {
    this.bundles = bundles;
  }

  async verify(
    request: IncomingMessage,
    session: SessionInfo,
    credential: string,
  ): Promise<VerifiedDeviceRequest> {
    if (!credential || credential.length > 8192 || /[\r\n]/.test(credential)) throw new Error('invalid_device_request_credential');
    const signingPublicKey = await this.bundles.signingKeyForSession(session.accountId, session.identityId, session.deviceId);
    if (!signingPublicKey) {
      if (bootstrapBundlePath(request, session)) {
        return { deviceId: session.deviceId, bodySha256: '', timestampMs: 0, nonce: '', bootstrap: true };
      }
      throw new Error('device_key_bundle_required');
    }

    const deviceId = singleHeader(request, 'x-loom-device-id');
    const timestampRaw = singleHeader(request, 'x-loom-request-timestamp');
    const nonce = singleHeader(request, 'x-loom-request-nonce');
    const bodySha256 = singleHeader(request, 'x-loom-content-sha256').toLowerCase();
    const signature = singleHeader(request, 'x-loom-request-signature');

    if (deviceId !== session.deviceId) throw new Error('device_request_session_mismatch');
    if (!/^dev_[0-9a-f-]{36}$/i.test(deviceId)) throw new Error('invalid_device_request_proof');
    if (!/^\d{13}$/.test(timestampRaw)) throw new Error('invalid_device_request_timestamp');
    const timestampMs = Number(timestampRaw);
    if (!Number.isSafeInteger(timestampMs) || Math.abs(Date.now() - timestampMs) > 2 * 60_000) throw new Error('stale_device_request');
    if (!/^[A-Za-z0-9_-]{24,128}$/.test(nonce)) throw new Error('invalid_device_request_nonce');
    if (!/^[0-9a-f]{64}$/.test(bodySha256)) throw new Error('invalid_device_request_body_hash');
    const method = (request.method ?? 'GET').toUpperCase();
    if ((method === 'GET' || method === 'HEAD') && bodySha256 !== EMPTY_BODY_SHA256) throw new Error('device_request_body_hash_mismatch');

    const canonical = canonicalDeviceRequestProof({
      method,
      target: targetFor(request),
      bodySha256,
      timestampMs: timestampRaw,
      nonce,
      deviceId,
      credentialSha256: sha256Hex(credential),
    });
    if (!verifyRawEd25519(Buffer.from(canonical, 'utf8'), signature, signingPublicKey)) throw new Error('invalid_device_request_signature');
    const remembered = await this.bundles.rememberRequestNonce(deviceId, nonce, new Date(Date.now() + 10 * 60_000));
    if (!remembered) throw new Error('device_request_replay_detected');
    return { deviceId, bodySha256, timestampMs, nonce, bootstrap: false };
  }
}
