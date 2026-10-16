import { createPublicKey, verify } from 'node:crypto';

const RECEIPT_DOMAIN = 'loom-proximity-recipient-delivery-v1';
const ED25519_SPKI_PREFIX = Buffer.from('302a300506032b6570032100', 'hex');
const MAX_CLOCK_SKEW_MS = 2 * 60_000;

export interface V2RecipientDeliveryReceipt {
  version: 1;
  leaseId: string;
  deliveryId: string;
  recipientDeviceId: string;
  acceptedAt: string;
  signature: string;
}

function text(value: unknown, label: string, max: number): string {
  if (
    typeof value !== 'string' ||
    value.trim() !== value ||
    value.length < 1 ||
    value.length > max ||
    /[\r\n\0]/.test(value)
  ) throw new Error(`invalid_gateway_recipient_receipt_${label}`);
  return value;
}

function b64url(value: unknown, label: string, bytes: number): Buffer {
  const encoded = text(value, label, 128);
  if (!/^[A-Za-z0-9_-]+$/.test(encoded)) {
    throw new Error(`invalid_gateway_recipient_receipt_${label}`);
  }
  const decoded = Buffer.from(encoded, 'base64url');
  if (decoded.length !== bytes || decoded.toString('base64url') !== encoded) {
    throw new Error(`invalid_gateway_recipient_receipt_${label}`);
  }
  return decoded;
}

function ed25519Key(raw: Buffer) {
  return createPublicKey({
    key: Buffer.concat([ED25519_SPKI_PREFIX, raw]),
    format: 'der',
    type: 'spki',
  });
}

export function canonicalRecipientDeliveryReceiptBytes(
  receipt: Omit<V2RecipientDeliveryReceipt, 'signature'>,
): Buffer {
  return Buffer.from(JSON.stringify([
    RECEIPT_DOMAIN,
    receipt.version,
    receipt.leaseId,
    receipt.deliveryId,
    receipt.recipientDeviceId,
    receipt.acceptedAt,
  ]), 'utf8');
}

export function verifyRecipientDeliveryReceipt(
  input: unknown,
  expectedLeaseId: string,
  expectedRecipientDeviceId: string,
  recipientSigningPublicKeyBase64: string,
  now = Date.now(),
): V2RecipientDeliveryReceipt {
  if (!input || typeof input !== 'object' || Array.isArray(input)) {
    throw new Error('invalid_gateway_recipient_receipt');
  }
  const raw = input as Record<string, unknown>;
  if (raw.version !== 1) {
    throw new Error('invalid_gateway_recipient_receipt_version');
  }
  const leaseId = text(raw.leaseId, 'lease_id', 128);
  const deliveryId = text(raw.deliveryId, 'delivery_id', 256);
  const recipientDeviceId = text(raw.recipientDeviceId, 'device_id', 256);
  const acceptedAt = text(raw.acceptedAt, 'accepted_at', 64);
  const acceptedMs = Date.parse(acceptedAt);
  if (
    !Number.isFinite(acceptedMs) ||
    new Date(acceptedMs).toISOString() !== acceptedAt ||
    Math.abs(now - acceptedMs) > MAX_CLOCK_SKEW_MS
  ) throw new Error('stale_gateway_recipient_receipt');
  if (
    leaseId !== expectedLeaseId ||
    recipientDeviceId !== expectedRecipientDeviceId ||
    !deliveryId.startsWith('legacy:')
  ) throw new Error('invalid_gateway_recipient_receipt_binding');

  const signatureBytes = b64url(raw.signature, 'signature', 64);
  const signingKey = Buffer.from(recipientSigningPublicKeyBase64, 'base64');
  if (
    signingKey.length !== 32 ||
    signingKey.toString('base64') !== recipientSigningPublicKeyBase64
  ) throw new Error('invalid_gateway_recipient_receipt_key');

  const receipt: V2RecipientDeliveryReceipt = {
    version: 1,
    leaseId,
    deliveryId,
    recipientDeviceId,
    acceptedAt,
    signature: String(raw.signature),
  };
  const unsigned = { ...receipt } as Record<string, unknown>;
  delete unsigned.signature;
  if (!verify(
    null,
    canonicalRecipientDeliveryReceiptBytes(
      unsigned as Omit<V2RecipientDeliveryReceipt, 'signature'>,
    ),
    ed25519Key(signingKey),
    signatureBytes,
  )) throw new Error('invalid_gateway_recipient_receipt_signature');
  return receipt;
}
