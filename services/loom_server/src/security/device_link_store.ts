import { createHash, timingSafeEqual } from 'node:crypto';
import type { SessionInfo } from '../storage/sqlite_store.ts';

export interface DeviceLinkInvitationInput {
  linkId: string;
  tokenHash: string;
  payload: string;
}

export interface DeviceLinkInvitation {
  linkId: string;
  accountId: string;
  identityId: string;
  sourceDeviceId: string;
  tokenHash: string;
  payload: string;
  expiresAt: string;
  targetDeviceId: string | null;
}

function validLinkId(value: string): boolean {
  return /^dl_[A-Za-z0-9_-]{20,80}$/.test(value);
}

function validTokenHash(value: string): boolean {
  return /^[0-9a-f]{64}$/.test(value);
}

function hashToken(value: string): Buffer {
  return createHash('sha256').update(value, 'utf8').digest();
}

function safeHashEqual(expectedHex: string, actual: Buffer): boolean {
  const expected = Buffer.from(expectedHex, 'hex');
  return expected.length === actual.length && timingSafeEqual(expected, actual);
}

/**
 * Short-lived, one-target-device relay for device linking.
 *
 * The Home Node never receives recovery entropy or device agreement keys in
 * plaintext. It only holds an opaque client-encrypted package for a few
 * minutes. Invitations intentionally disappear on process restart.
 */
export class DeviceLinkStore {
  private readonly invitations = new Map<string, DeviceLinkInvitation>();
  private readonly ttlMs: number;

  constructor(ttlMs = 5 * 60_000) {
    this.ttlMs = ttlMs;
  }

  create(session: SessionInfo, input: DeviceLinkInvitationInput): DeviceLinkInvitation {
    this.prune();
    const linkId = input.linkId.trim();
    const tokenHash = input.tokenHash.trim().toLowerCase();
    const payload = input.payload.trim();
    if (!validLinkId(linkId)) throw new Error('invalid_device_link_id');
    if (!validTokenHash(tokenHash)) throw new Error('invalid_device_link_token');
    if (payload.length < 32 || Buffer.byteLength(payload, 'utf8') > 96 * 1024) {
      throw new Error('invalid_device_link_payload');
    }
    // Refuse old token-derived envelopes, even when an old client is used.
    // A compliant envelope carries no out-of-band content-encryption secret.
    let envelope: Record<string, unknown>;
    try { envelope = JSON.parse(payload) as Record<string, unknown>; }
    catch { throw new Error('invalid_device_link_payload'); }
    const fields = ['v', 'protocol', 'nonce', 'ciphertext', 'mac'];
    if (!envelope || Array.isArray(envelope) || envelope.v !== 2 ||
        envelope.protocol !== 'loom-device-link-v2' ||
        Object.keys(envelope).some(key => !fields.includes(key))) {
      throw new Error('invalid_device_link_payload');
    }
    for (const [key, length] of [['nonce', 12], ['mac', 16], ['ciphertext', null]] as const) {
      const value = envelope[key];
      if (typeof value !== 'string' || !/^[A-Za-z0-9+/]+={0,2}$/.test(value)) throw new Error('invalid_device_link_payload');
      const bytes = Buffer.from(value, 'base64');
      if (bytes.toString('base64') !== value || (length !== null ? bytes.length !== length : bytes.length < 32)) throw new Error('invalid_device_link_payload');
    }
    if (this.invitations.has(linkId)) throw new Error('device_link_exists');
    const accountActive = [...this.invitations.values()].filter(
      (item) => item.accountId === session.accountId,
    ).length;
    if (accountActive >= 5 || this.invitations.size >= 5000) {
      throw new Error('device_link_limit');
    }
    const invitation: DeviceLinkInvitation = {
      linkId,
      accountId: session.accountId,
      identityId: session.identityId,
      sourceDeviceId: session.deviceId,
      tokenHash,
      payload,
      expiresAt: new Date(Date.now() + this.ttlMs).toISOString(),
      targetDeviceId: null,
    };
    this.invitations.set(linkId, invitation);
    return invitation;
  }

  redeem(session: SessionInfo, linkIdInput: string, tokenInput: string): DeviceLinkInvitation {
    this.prune();
    const linkId = linkIdInput.trim();
    const token = tokenInput.trim();
    if (!validLinkId(linkId)) throw new Error('invalid_device_link_id');
    if (!/^[A-Za-z0-9_-]{40,80}$/.test(token)) {
      throw new Error('invalid_device_link_token');
    }
    const invitation = this.invitations.get(linkId);
    if (!invitation) throw new Error('device_link_not_found');
    if (Date.parse(invitation.expiresAt) <= Date.now()) {
      this.invitations.delete(linkId);
      throw new Error('device_link_expired');
    }
    if (invitation.accountId !== session.accountId ||
        invitation.identityId !== session.identityId) {
      throw new Error('device_link_account_mismatch');
    }
    if (invitation.sourceDeviceId === session.deviceId) {
      throw new Error('device_link_same_device');
    }
    if (!safeHashEqual(invitation.tokenHash, hashToken(token))) {
      throw new Error('device_link_token_mismatch');
    }
    if (invitation.targetDeviceId != null &&
        invitation.targetDeviceId !== session.deviceId) {
      throw new Error('device_link_target_mismatch');
    }
    if (invitation.targetDeviceId == null) {
      invitation.targetDeviceId = session.deviceId;
      this.invitations.set(linkId, invitation);
    }
    return invitation;
  }

  complete(session: SessionInfo, linkIdInput: string): void {
    const linkId = linkIdInput.trim();
    const invitation = this.invitations.get(linkId);
    if (!invitation) return;
    if (invitation.accountId !== session.accountId ||
        invitation.identityId !== session.identityId ||
        invitation.targetDeviceId !== session.deviceId) {
      throw new Error('device_link_target_mismatch');
    }
    this.invitations.delete(linkId);
  }

  private prune(): void {
    const now = Date.now();
    for (const [linkId, invitation] of this.invitations) {
      if (Date.parse(invitation.expiresAt) <= now) this.invitations.delete(linkId);
    }
  }
}
