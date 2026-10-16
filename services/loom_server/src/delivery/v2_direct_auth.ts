import { createHash, createPublicKey, verify } from 'node:crypto';

const DIRECT_PROOF_DOMAIN = 'loom-direct-node-v1';
const MAX_CLOCK_SKEW_MS = 5 * 60_000;
const ED25519_SPKI_PREFIX = Buffer.from('302a300506032b6570032100', 'hex');

export interface V2DirectTransportProof {
  devicePublicKey: string;
  issuedAt: string;
  nonce: string;
  signature: string;
}

type DirectPacketInput = Record<string, unknown>;

function requireText(value: unknown, label: string, max: number): string {
  if (
    typeof value !== 'string' ||
    value.trim() !== value ||
    value.length < 1 ||
    value.length > max ||
    /[\r\n\0]/.test(value)
  ) {
    throw new Error(`invalid_direct_${label}`);
  }
  return value;
}

function requireBase64Url(
  value: unknown,
  label: string,
  minBytes: number,
  maxBytes: number,
): { encoded: string; bytes: Buffer } {
  const encoded = requireText(value, label, Math.ceil((maxBytes * 4) / 3) + 8);
  if (!/^[A-Za-z0-9_-]+$/.test(encoded)) {
    throw new Error(`invalid_direct_${label}`);
  }
  const bytes = Buffer.from(encoded, 'base64url');
  if (
    bytes.length < minBytes ||
    bytes.length > maxBytes ||
    bytes.toString('base64url') !== encoded
  ) {
    throw new Error(`invalid_direct_${label}`);
  }
  return { encoded, bytes };
}

export function canonicalV2DirectPacketBytes(
  input: DirectPacketInput,
  proof: Omit<V2DirectTransportProof, 'signature'>,
): Buffer {
  const packetId = requireText(input.packetId, 'packet_id', 128);
  const mailboxToken = requireText(input.mailboxToken, 'mailbox_token', 256);
  const envelopeBase64 = requireText(input.envelopeBase64, 'packet_envelope', 2 * 1024 * 1024);
  const expiresAt = requireText(input.expiresAt, 'packet_expiry', 64);
  const priority = requireText(input.priority, 'packet_priority', 16);
  if (priority !== 'normal' && priority !== 'urgent') {
    throw new Error('invalid_direct_packet_priority');
  }
  const issuedAt = requireText(proof.issuedAt, 'issued_at', 64);
  const nonce = requireText(proof.nonce, 'nonce', 128);
  const devicePublicKey = requireText(proof.devicePublicKey, 'device_public_key', 128);

  return Buffer.from(JSON.stringify([
    DIRECT_PROOF_DOMAIN,
    issuedAt,
    nonce,
    devicePublicKey,
    packetId,
    mailboxToken,
    envelopeBase64,
    expiresAt,
    priority,
  ]), 'utf8');
}

export function verifyV2DirectTransportProof(
  input: DirectPacketInput,
  proofInput: unknown,
  now = Date.now(),
): string {
  if (!proofInput || typeof proofInput !== 'object' || Array.isArray(proofInput)) {
    throw new Error('invalid_direct_transport_proof');
  }
  const raw = proofInput as Record<string, unknown>;
  const devicePublicKey = requireBase64Url(
    raw.devicePublicKey,
    'device_public_key',
    32,
    32,
  );
  const nonce = requireBase64Url(raw.nonce, 'nonce', 16, 64);
  const signature = requireBase64Url(raw.signature, 'signature', 64, 64);
  const issuedAt = requireText(raw.issuedAt, 'issued_at', 64);
  const issuedMs = Date.parse(issuedAt);
  if (!Number.isFinite(issuedMs) || new Date(issuedMs).toISOString() !== issuedAt) {
    throw new Error('invalid_direct_issued_at');
  }
  if (Math.abs(now - issuedMs) > MAX_CLOCK_SKEW_MS) {
    throw new Error('stale_direct_transport_proof');
  }

  const proof = {
    devicePublicKey: devicePublicKey.encoded,
    issuedAt,
    nonce: nonce.encoded,
  };
  const canonical = canonicalV2DirectPacketBytes(input, proof);
  const publicKey = createPublicKey({
    key: Buffer.concat([ED25519_SPKI_PREFIX, devicePublicKey.bytes]),
    format: 'der',
    type: 'spki',
  });
  if (!verify(null, canonical, publicKey, signature.bytes)) {
    throw new Error('invalid_direct_transport_signature');
  }

  return createHash('sha256')
    .update(devicePublicKey.bytes)
    .digest('base64url');
}
