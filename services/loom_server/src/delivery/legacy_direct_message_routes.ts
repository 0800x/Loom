import { timingSafeEqual } from 'node:crypto';
import type { IncomingMessage, ServerResponse } from 'node:http';
import { parseLoomAddress } from '../federation/address.ts';
import type { FederationRoutingStore } from '../federation/routing_store.ts';
import { decodeCanonicalBase64, verifyRawEd25519 } from '../identity/public_material.ts';
import { json, readJson } from '../http/http.ts';
import type { DeviceBundleStore } from '../security/device_bundle_store.ts';
import type { SessionInfo } from '../storage/sqlite_store.ts';

const PROOF_DOMAIN = 'loom-nearby-message-gateway-v1';
const MAX_CLOCK_SKEW_MS = 5 * 60_000;

export type LegacyDirectMessagePayload = {
  conversationId: string;
  clientId: string;
  type: string;
  ciphertext: string;
  protocolVersion: string;
  replyToMessageId?: string | null;
  metadata: Record<string, unknown>;
};

type DeliverMessage = (
  session: SessionInfo,
  payload: LegacyDirectMessagePayload,
) => Promise<Record<string, unknown>>;

type VerifiedRequest = {
  session: SessionInfo;
  payload: LegacyDirectMessagePayload;
};

function requireText(value: unknown, label: string, max: number): string {
  if (
    typeof value !== 'string' ||
    value.trim() !== value ||
    value.length < 1 ||
    value.length > max ||
    /[\r\n\0]/.test(value)
  ) {
    throw new Error(`invalid_legacy_direct_${label}`);
  }
  return value;
}

function requireBase64Url(
  value: unknown,
  label: string,
  minBytes: number,
  maxBytes: number,
): { encoded: string; bytes: Buffer } {
  const encoded = requireText(
    value,
    label,
    Math.ceil((maxBytes * 4) / 3) + 8,
  );
  if (!/^[A-Za-z0-9_-]+$/.test(encoded)) {
    throw new Error(`invalid_legacy_direct_${label}`);
  }
  const bytes = Buffer.from(encoded, 'base64url');
  if (
    bytes.length < minBytes ||
    bytes.length > maxBytes ||
    bytes.toString('base64url') !== encoded
  ) {
    throw new Error(`invalid_legacy_direct_${label}`);
  }
  return { encoded, bytes };
}

function canonicalProofBytes(input: {
  homeNodeDomain: string;
  accountId: string;
  identityId: string;
  deviceId: string;
  senderAddress: string;
  devicePublicKey: string;
  issuedAt: string;
  nonce: string;
  payloadBase64: string;
}): Buffer {
  return Buffer.from(JSON.stringify([
    PROOF_DOMAIN,
    input.homeNodeDomain,
    input.accountId,
    input.identityId,
    input.deviceId,
    input.senderAddress,
    input.devicePublicKey,
    input.issuedAt,
    input.nonce,
    input.payloadBase64,
  ]), 'utf8');
}

function parsePayload(payloadBase64: string): LegacyDirectMessagePayload {
  const bytes = Buffer.from(payloadBase64, 'base64url');
  if (bytes.length < 2 || bytes.length > 1024 * 1024) {
    throw new Error('invalid_legacy_direct_payload');
  }
  let raw: unknown;
  try {
    raw = JSON.parse(bytes.toString('utf8'));
  } catch {
    throw new Error('invalid_legacy_direct_payload');
  }
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) {
    throw new Error('invalid_legacy_direct_payload');
  }
  const body = raw as Record<string, unknown>;
  const conversationId = requireText(body.conversationId, 'conversation_id', 256);
  const clientId = requireText(body.clientId, 'client_id', 256);
  const type = requireText(body.type, 'message_type', 32);
  const ciphertext = requireText(body.ciphertext, 'ciphertext', 1024 * 1024);
  const protocolVersion = requireText(body.protocolVersion, 'protocol_version', 128);
  const replyRaw = body.replyToMessageId;
  const replyToMessageId = replyRaw == null
    ? null
    : requireText(replyRaw, 'reply_to_message_id', 256);
  const metadataRaw = body.metadata ?? {};
  if (!metadataRaw || typeof metadataRaw !== 'object' || Array.isArray(metadataRaw)) {
    throw new Error('invalid_legacy_direct_metadata');
  }
  return {
    conversationId,
    clientId,
    type,
    ciphertext,
    protocolVersion,
    replyToMessageId,
    metadata: metadataRaw as Record<string, unknown>,
  };
}

export class LegacyDirectMessageRoutes {
  private readonly bundles: DeviceBundleStore;
  private readonly federationRouting: FederationRoutingStore;
  private readonly publicDomain: string;
  private readonly maxRequestBytes: number;
  private readonly deliver: DeliverMessage;

  constructor(
    bundles: DeviceBundleStore,
    federationRouting: FederationRoutingStore,
    publicDomain: string,
    maxRequestBytes: number,
    deliver: DeliverMessage,
  ) {
    this.bundles = bundles;
    this.federationRouting = federationRouting;
    this.publicDomain = publicDomain;
    this.maxRequestBytes = maxRequestBytes;
    this.deliver = deliver;
  }

  async tryHandle(
    method: string,
    url: URL,
    request: IncomingMessage,
    response: ServerResponse,
  ): Promise<boolean> {
    if (method !== 'POST' || url.pathname !== '/api/v1/messages/direct') {
      return false;
    }
    try {
      const body = await readJson(
        request,
        Math.min(this.maxRequestBytes, 2 * 1024 * 1024),
      );
      const verified = await this.verify(body);
      const receipt = await this.deliver(verified.session, verified.payload);
      json(response, 201, receipt);
    } catch (error) {
      const code = error instanceof Error ? error.message : 'internal_error';
      const rejected =
        code.startsWith('invalid_legacy_direct_') ||
        code === 'stale_legacy_direct_proof' ||
        code === 'legacy_direct_device_not_authorized' ||
        code === 'legacy_direct_sender_mismatch' ||
        code === 'legacy_direct_replay_detected' ||
        code === 'body_too_large' ||
        code === 'content_type' ||
        code === 'json_object_required';
      if (!rejected) {
        console.error('[loom-node] direct legacy message ingress failed', error);
      }
      json(response, rejected ? 403 : 500, {
        error: rejected ? code : 'internal_error',
      });
    }
    return true;
  }

  private async verify(body: Record<string, unknown>): Promise<VerifiedRequest> {
    const homeNodeDomain = requireText(
      body.homeNodeDomain,
      'home_node_domain',
      253,
    ).toLowerCase();
    if (homeNodeDomain !== this.publicDomain.toLowerCase()) {
      throw new Error('legacy_direct_sender_mismatch');
    }
    const accountId = requireText(body.accountId, 'account_id', 256);
    const identityId = requireText(body.identityId, 'identity_id', 256);
    const deviceId = requireText(body.deviceId, 'device_id', 256);
    const senderAddress = requireText(body.senderAddress, 'sender_address', 512);
    const payload = requireBase64Url(
      body.payloadBase64,
      'payload',
      2,
      1024 * 1024,
    );
    const proofRaw = body.transportProof;
    if (!proofRaw || typeof proofRaw !== 'object' || Array.isArray(proofRaw)) {
      throw new Error('invalid_legacy_direct_transport_proof');
    }
    const proof = proofRaw as Record<string, unknown>;
    const devicePublicKey = requireBase64Url(
      proof.devicePublicKey,
      'device_public_key',
      32,
      32,
    );
    const signature = requireBase64Url(
      proof.signature,
      'signature',
      64,
      64,
    );
    const nonce = requireBase64Url(proof.nonce, 'nonce', 16, 64);
    const issuedAt = requireText(proof.issuedAt, 'issued_at', 64);
    const issuedMs = Date.parse(issuedAt);
    if (!Number.isFinite(issuedMs) || new Date(issuedMs).toISOString() !== issuedAt) {
      throw new Error('invalid_legacy_direct_issued_at');
    }
    if (Math.abs(Date.now() - issuedMs) > MAX_CLOCK_SKEW_MS) {
      throw new Error('stale_legacy_direct_proof');
    }

    const signingPublicKey = await this.bundles.signingKeyForSession(
      accountId,
      identityId,
      deviceId,
    );
    if (!signingPublicKey) {
      throw new Error('legacy_direct_device_not_authorized');
    }
    const registeredKey = decodeCanonicalBase64(
      signingPublicKey,
      32,
      'legacy_direct_device_not_authorized',
    );
    if (
      registeredKey.length !== devicePublicKey.bytes.length ||
      !timingSafeEqual(registeredKey, devicePublicKey.bytes)
    ) {
      throw new Error('legacy_direct_device_not_authorized');
    }

    const canonical = canonicalProofBytes({
      homeNodeDomain,
      accountId,
      identityId,
      deviceId,
      senderAddress,
      devicePublicKey: devicePublicKey.encoded,
      issuedAt,
      nonce: nonce.encoded,
      payloadBase64: payload.encoded,
    });
    if (!verifyRawEd25519(
      canonical,
      signature.bytes.toString('base64'),
      registeredKey.toString('base64'),
    )) {
      throw new Error('invalid_legacy_direct_signature');
    }

    const address = parseLoomAddress(senderAddress, this.publicDomain);
    if (!address.isLocal || address.canonical !== senderAddress) {
      throw new Error('legacy_direct_sender_mismatch');
    }
    const profile = await this.federationRouting.resolveLocalUser(
      address.username,
      address.domain,
    );
    if (!profile || profile.identity.identityId !== identityId) {
      throw new Error('legacy_direct_sender_mismatch');
    }

    const remembered = await this.bundles.rememberRequestNonce(
      deviceId,
      nonce.encoded,
      new Date(Date.now() + 10 * 60_000),
    );
    if (!remembered) {
      throw new Error('legacy_direct_replay_detected');
    }

    return {
      session: {
        accountId,
        identityId,
        deviceId,
        username: address.username,
      },
      payload: parsePayload(payload.encoded),
    };
  }
}
