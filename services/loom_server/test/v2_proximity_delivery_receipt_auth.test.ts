import test from 'node:test';
import assert from 'node:assert/strict';
import {
  generateKeyPairSync,
  sign,
  type KeyObject,
} from 'node:crypto';
import {
  canonicalRecipientDeliveryReceiptBytes,
  verifyRecipientDeliveryReceipt,
  type V2RecipientDeliveryReceipt,
} from '../src/delivery/v2_proximity_delivery_receipt_auth.ts';

function rawPublic(key: KeyObject): Buffer {
  const der = key.export({ format: 'der', type: 'spki' }) as Buffer;
  return der.subarray(der.length - 32);
}

test('recipient delivery receipt binds lease, device and delivery id', () => {
  const now = Date.now();
  const recipient = generateKeyPairSync('ed25519');
  const recipientPublicBase64 = rawPublic(recipient.publicKey).toString('base64');
  const unsigned: Omit<V2RecipientDeliveryReceipt, 'signature'> = {
    version: 1,
    leaseId: 'lease-test-0123456789',
    deliveryId: 'legacy:event-test-0123456789',
    recipientDeviceId: 'device-recipient-0123456789',
    acceptedAt: new Date(now).toISOString(),
  };
  const receipt: V2RecipientDeliveryReceipt = {
    ...unsigned,
    signature: sign(
      null,
      canonicalRecipientDeliveryReceiptBytes(unsigned),
      recipient.privateKey,
    ).toString('base64url'),
  };

  const verified = verifyRecipientDeliveryReceipt(
    receipt,
    unsigned.leaseId,
    unsigned.recipientDeviceId,
    recipientPublicBase64,
    now,
  );
  assert.equal(verified.deliveryId, unsigned.deliveryId);

  assert.throws(() => verifyRecipientDeliveryReceipt(
    { ...receipt, deliveryId: 'legacy:event-tampered-0123456789' },
    unsigned.leaseId,
    unsigned.recipientDeviceId,
    recipientPublicBase64,
    now,
  ), /invalid_gateway_recipient_receipt_signature/);

  assert.throws(() => verifyRecipientDeliveryReceipt(
    receipt,
    'lease-other-0123456789',
    unsigned.recipientDeviceId,
    recipientPublicBase64,
    now,
  ), /invalid_gateway_recipient_receipt_binding/);
});
