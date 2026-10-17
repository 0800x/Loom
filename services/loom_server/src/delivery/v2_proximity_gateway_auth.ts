import { createHash, createPublicKey, verify } from 'node:crypto';

const LEASE_DOMAIN = 'loom-proximity-gateway-lease-v1';
const PROOF_DOMAIN = 'loom-proximity-gateway-proof-v1';
const ED25519_SPKI_PREFIX = Buffer.from('302a300506032b6570032100', 'hex');
const MAX_CLOCK_SKEW_MS = 2 * 60_000;
const MAX_LEASE_LIFETIME_MS = 2 * 60_000;

export type ProximityBearer = 'ble' | 'wifi-direct' | 'wifi-aware';
export type GatewayProofAction = 'register' | 'claim' | 'custody';

export interface V2ProximityGatewayLease {
  version: 1;
  leaseId: string;
  sessionId: string;
  recipientIdentityId: string;
  recipientDeviceId: string;
  recipientNodeId: string;
  recipientNodeDomain: string;
  gatewayDevicePublicKey: string;
  gatewayFingerprint: string;
  gatewayEphemeralPublicKey: string;
  recipientEphemeralPublicKey: string;
  bearer: ProximityBearer;
  issuedAt: string;
  expiresAt: string;
  nonce: string;
  maxPackets: number;
  maxBytes: number;
  signature: string;
}

export interface V2GatewayTransportProof {
  devicePublicKey: string;
  issuedAt: string;
  nonce: string;
  signature: string;
}

function text(value: unknown, label: string, min: number, max: number): string {
  if (
    typeof value !== 'string' ||
    value.trim() !== value ||
    value.length < min ||
    value.length > max ||
    /[\r\n\0]/.test(value)
  ) {
    throw new Error(`invalid_gateway_${label}`);
  }
  return value;
}

function b64url(
  value: unknown,
  label: string,
  minBytes: number,
  maxBytes: number,
): { encoded: string; bytes: Buffer } {
  const encoded = text(value, label, 1, Math.ceil((maxBytes * 4) / 3) + 8);
  if (!/^[A-Za-z0-9_-]+$/.test(encoded)) {
    throw new Error(`invalid_gateway_${label}`);
  }
  const bytes = Buffer.from(encoded, 'base64url');
  if (
    bytes.length < minBytes ||
    bytes.length > maxBytes ||
    bytes.toString('base64url') !== encoded
  ) {
    throw new Error(`invalid_gateway_${label}`);
  }
  return { encoded, bytes };
}

function iso(value: unknown, label: string): { value: string; ms: number } {
  const raw = text(value, label, 20, 64);
  const ms = Date.parse(raw);
  if (!Number.isFinite(ms) || new Date(ms).toISOString() !== raw) {
    throw new Error(`invalid_gateway_${label}`);
  }
  return { value: raw, ms };
}

function integer(
  value: unknown,
  label: string,
  min: number,
  max: number,
): number {
  if (!Number.isInteger(value) || Number(value) < min || Number(value) > max) {
    throw new Error(`invalid_gateway_${label}`);
  }
  return Number(value);
}

function fingerprint(publicKey: Buffer): string {
  return createHash('sha256').update(publicKey).digest('base64url');
}

function ed25519Key(raw: Buffer) {
  return createPublicKey({
    key: Buffer.concat([ED25519_SPKI_PREFIX, raw]),
    format: 'der',
    type: 'spki',
  });
}

function domain(value: unknown): string {
  const raw = text(value, 'recipient_node_domain', 3, 253).toLowerCase();
  if (
    raw.includes('://') ||
    raw.includes('/') ||
    raw.includes(':') ||
    !/^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$/.test(raw) ||
    raw.includes('..') ||
    !raw.includes('.')
  ) {
    throw new Error('invalid_gateway_recipient_node_domain');
  }
  return raw;
}

export function canonicalProximityLeaseBytes(
  lease: Omit<V2ProximityGatewayLease, 'signature'>,
): Buffer {
  return Buffer.from(JSON.stringify([
    LEASE_DOMAIN,
    lease.version,
    lease.leaseId,
    lease.sessionId,
    lease.recipientIdentityId,
    lease.recipientDeviceId,
    lease.recipientNodeId,
    lease.recipientNodeDomain,
    lease.gatewayDevicePublicKey,
    lease.gatewayFingerprint,
    lease.gatewayEphemeralPublicKey,
    lease.recipientEphemeralPublicKey,
    lease.bearer,
    lease.issuedAt,
    lease.expiresAt,
    lease.nonce,
    lease.maxPackets,
    lease.maxBytes,
  ]), 'utf8');
}

export function parseProximityGatewayLease(
  input: unknown,
  now = Date.now(),
): V2ProximityGatewayLease {
  if (!input || typeof input !== 'object' || Array.isArray(input)) {
    throw new Error('invalid_gateway_lease');
  }
  const raw = input as Record<string, unknown>;
  if (raw.version !== 1) throw new Error('invalid_gateway_lease_version');
  const leaseId = text(raw.leaseId, 'lease_id', 8, 128);
  const sessionId = text(raw.sessionId, 'session_id', 8, 128);
  const recipientIdentityId = text(raw.recipientIdentityId, 'recipient_identity_id', 8, 128);
  if (!recipientIdentityId.startsWith('chn:')) {
    throw new Error('invalid_gateway_recipient_identity_id');
  }
  const recipientDeviceId = text(raw.recipientDeviceId, 'recipient_device_id', 8, 256);
  const recipientNodeId = text(raw.recipientNodeId, 'recipient_node_id', 8, 256);
  if (!recipientNodeId.startsWith('node:')) {
    throw new Error('invalid_gateway_recipient_node_id');
  }
  const recipientNodeDomain = domain(raw.recipientNodeDomain);
  const gatewayKey = b64url(raw.gatewayDevicePublicKey, 'device_public_key', 32, 32);
  const gatewayFingerprint = text(raw.gatewayFingerprint, 'fingerprint', 32, 128);
  if (gatewayFingerprint !== fingerprint(gatewayKey.bytes)) {
    throw new Error('invalid_gateway_fingerprint');
  }
  const gatewayEphemeralPublicKey = b64url(
    raw.gatewayEphemeralPublicKey,
    'gateway_ephemeral_public_key',
    32,
    32,
  ).encoded;
  const recipientEphemeralPublicKey = b64url(
    raw.recipientEphemeralPublicKey,
    'recipient_ephemeral_public_key',
    32,
    32,
  ).encoded;
  const bearer = raw.bearer;
  if (bearer !== 'ble' && bearer !== 'wifi-direct' && bearer !== 'wifi-aware') {
    throw new Error('invalid_gateway_bearer');
  }
  const issued = iso(raw.issuedAt, 'issued_at');
  const expires = iso(raw.expiresAt, 'expires_at');
  if (Math.abs(now - issued.ms) > MAX_CLOCK_SKEW_MS) {
    throw new Error('stale_gateway_lease');
  }
  if (
    expires.ms <= now ||
    expires.ms <= issued.ms ||
    expires.ms - issued.ms > MAX_LEASE_LIFETIME_MS
  ) {
    throw new Error('invalid_gateway_lease_expiry');
  }
  const nonce = b64url(raw.nonce, 'lease_nonce', 16, 64).encoded;
  const maxPackets = integer(raw.maxPackets, 'max_packets', 1, 50);
  const maxBytes = integer(raw.maxBytes, 'max_bytes', 1024, 1024 * 1024);
  const signature = b64url(raw.signature, 'lease_signature', 64, 64).encoded;
  return {
    version: 1,
    leaseId,
    sessionId,
    recipientIdentityId,
    recipientDeviceId,
    recipientNodeId,
    recipientNodeDomain,
    gatewayDevicePublicKey: gatewayKey.encoded,
    gatewayFingerprint,
    gatewayEphemeralPublicKey,
    recipientEphemeralPublicKey,
    bearer,
    issuedAt: issued.value,
    expiresAt: expires.value,
    nonce,
    maxPackets,
    maxBytes,
    signature,
  };
}

export function verifyRecipientSignedProximityLease(
  input: unknown,
  recipientSigningPublicKeyBase64: string,
  now = Date.now(),
): V2ProximityGatewayLease {
  const lease = parseProximityGatewayLease(input, now);
  const recipientRaw = Buffer.from(recipientSigningPublicKeyBase64, 'base64');
  if (
    recipientRaw.length !== 32 ||
    recipientRaw.toString('base64') !== recipientSigningPublicKeyBase64
  ) {
    throw new Error('invalid_gateway_recipient_signing_key');
  }
  const signature = Buffer.from(lease.signature, 'base64url');
  const unsigned = { ...lease } as Record<string, unknown>;
  delete unsigned.signature;
  if (!verify(
    null,
    canonicalProximityLeaseBytes(unsigned as Omit<V2ProximityGatewayLease, 'signature'>),
    ed25519Key(recipientRaw),
    signature,
  )) {
    throw new Error('invalid_gateway_recipient_signature');
  }
  return lease;
}

export function canonicalGatewayProofBytes(
  action: GatewayProofAction,
  context: Record<string, unknown>,
  proof: Omit<V2GatewayTransportProof, 'signature'>,
): Buffer {
  const packetIds = Array.isArray(context.packetIds)
    ? [...context.packetIds].map(String).sort()
    : [];
  return Buffer.from(JSON.stringify([
    PROOF_DOMAIN,
    action,
    proof.issuedAt,
    proof.nonce,
    proof.devicePublicKey,
    String(context.leaseId ?? ''),
    String(context.recipientDeviceId ?? ''),
    Number(context.limit ?? 0),
    packetIds,
  ]), 'utf8');
}

export function verifyGatewayTransportProof(
  action: GatewayProofAction,
  context: Record<string, unknown>,
  proofInput: unknown,
  now = Date.now(),
): { fingerprint: string; publicKey: string; nonce: string; issuedAt: string } {
  if (!proofInput || typeof proofInput !== 'object' || Array.isArray(proofInput)) {
    throw new Error('invalid_gateway_transport_proof');
  }
  const raw = proofInput as Record<string, unknown>;
  const key = b64url(raw.devicePublicKey, 'device_public_key', 32, 32);
  const nonce = b64url(raw.nonce, 'proof_nonce', 16, 64);
  const signature = b64url(raw.signature, 'proof_signature', 64, 64);
  const issued = iso(raw.issuedAt, 'proof_issued_at');
  if (Math.abs(now - issued.ms) > MAX_CLOCK_SKEW_MS) {
    throw new Error('stale_gateway_transport_proof');
  }
  const unsigned = {
    devicePublicKey: key.encoded,
    issuedAt: issued.value,
    nonce: nonce.encoded,
  };
  if (!verify(
    null,
    canonicalGatewayProofBytes(action, context, unsigned),
    ed25519Key(key.bytes),
    signature.bytes,
  )) {
    throw new Error('invalid_gateway_transport_signature');
  }
  return {
    fingerprint: fingerprint(key.bytes),
    publicKey: key.encoded,
    nonce: nonce.encoded,
    issuedAt: issued.value,
  };
}
