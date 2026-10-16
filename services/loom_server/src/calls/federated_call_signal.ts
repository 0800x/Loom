import { randomUUID } from 'node:crypto';
import { validCallSdp } from './sdp.ts';

import type { LoomNodeConfig } from '../config/config.ts';
import { parseLoomAddress, normalizeLoomDomain } from '../federation/address.ts';
import type { FederationNodeRecord } from '../federation/node_registry.ts';
import { FederationService } from '../federation/service.ts';
import { safeFederationHttpsRequest } from '../federation/safe_https.ts';
import { LoomNodeIdentity } from '../identity/node_identity.ts';

export const CALL_FEDERATION_PROTOCOL = 'loom-call-federation-v1' as const;
const MAX_SIGNAL_AGE_MS = 2 * 60_000;
const MAX_FUTURE_SKEW_MS = 30_000;
const SIGNAL_KINDS = new Set([
  'call.offer',
  'call.ringing',
  'call.answer',
  'call.ice',
  'call.media',
  'call.reject',
  'call.busy',
  'call.end',
]);

export interface FederatedCallSignal {
  protocol: typeof CALL_FEDERATION_PROTOCOL;
  eventId: string;
  originNodeId: string;
  originDomain: string;
  destinationNodeId: string;
  destinationDomain: string;
  senderAddress: string;
  recipientAddress: string;
  senderIdentityId: string;
  targetIdentityId: string;
  senderDisplayName: string;
  callId: string;
  conversationId: string;
  kind: string;
  sequence: number;
  createdAt: string;
  mediaKind?: 'audio' | 'video';
  sdp?: string;
  sdpType?: string;
  candidate?: string;
  sdpMid?: string;
  sdpMLineIndex?: number;
  reason?: string;
  signature: string;
}

type UnsignedFederatedCallSignal = Omit<FederatedCallSignal, 'signature'>;

function canonical(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === 'object') {
    const out: Record<string, unknown> = {};
    const input = value as Record<string, unknown>;
    for (const key of Object.keys(input).sort()) out[key] = canonical(input[key]);
    return out;
  }
  return value;
}

function canonicalPayload(signal: UnsignedFederatedCallSignal): string {
  return JSON.stringify(canonical(signal));
}

function localEndpoint(peer: FederationNodeRecord): boolean {
  try {
    const host = new URL(peer.endpoint).hostname.toLowerCase();
    if (host === 'localhost' || host.endsWith('.local')) return true;
    const ipv4 = /^(\d+)\.(\d+)\.(\d+)\.(\d+)$/.exec(host.replace(/^::ffff:/, ''));
    if (ipv4) {
      const a = Number(ipv4[1]);
      const b = Number(ipv4[2]);
      return a === 10 || a === 127 || (a === 172 && b >= 16 && b <= 31) ||
        (a === 192 && b === 168) || (a === 169 && b === 254);
    }
    return host.startsWith('fc') || host.startsWith('fd') || /^fe[89ab]/.test(host);
  } catch {
    return false;
  }
}

function peerAllowed(config: LoomNodeConfig, peer: FederationNodeRecord): boolean {
  if (config.federationMode === 'disabled' || peer.trustState === 'blocked') return false;
  if (config.federationMode === 'open') return true;
  if (config.federationMode === 'trusted') return peer.trustState === 'trusted';
  if (config.federationMode === 'local') return localEndpoint(peer);
  if (config.federationMode === 'hybrid') {
    return peer.trustState === 'trusted' || localEndpoint(peer);
  }
  return false;
}

function validText(value: string, max: number): boolean {
  return value.length > 0 && value.length <= max && !/[\r\n]/.test(value);
}

function validateSignalFields(signal: FederatedCallSignal, now = Date.now()): void {
  if (signal.protocol !== CALL_FEDERATION_PROTOCOL) throw new Error('unsupported_call_federation_protocol');
  if (!/^fcallsig_[0-9a-f-]{36}$/i.test(signal.eventId)) throw new Error('invalid_call_federation_event_id');
  if (!SIGNAL_KINDS.has(signal.kind)) throw new Error('invalid_call_signal_kind');
  if (!validText(signal.callId, 200) || !validText(signal.conversationId, 256)) throw new Error('invalid_call_signal');
  if (!validText(signal.senderIdentityId, 128) || !validText(signal.targetIdentityId, 128)) throw new Error('invalid_call_identity');
  if (!validText(signal.senderDisplayName, 80)) throw new Error('invalid_call_display_name');
  if (!Number.isSafeInteger(signal.sequence) || signal.sequence < 0) throw new Error('invalid_call_sequence');
  const created = Date.parse(signal.createdAt);
  if (!Number.isFinite(created) || created < now - MAX_SIGNAL_AGE_MS || created > now + MAX_FUTURE_SKEW_MS) {
    throw new Error('stale_call_signal');
  }
  if (signal.mediaKind != null && signal.mediaKind !== 'audio' && signal.mediaKind !== 'video') {
    throw new Error('invalid_call_media_kind');
  }
  if (signal.sdp != null && !validCallSdp(signal.sdp)) throw new Error('invalid_call_sdp');
  if (signal.kind === 'call.offer' && (!signal.sdp || signal.sdpType !== 'offer' || !signal.mediaKind)) throw new Error('invalid_call_offer');
  if (signal.kind === 'call.answer' && (!signal.sdp || signal.sdpType !== 'answer')) throw new Error('invalid_call_answer');
  if (signal.candidate != null && Buffer.byteLength(signal.candidate, 'utf8') > 16 * 1024) throw new Error('call_candidate_too_large');
  if (signal.sdpType != null && !['offer', 'answer'].includes(signal.sdpType)) throw new Error('invalid_call_sdp_type');
  if (signal.sdpMid != null && signal.sdpMid.length > 256) throw new Error('invalid_call_sdp_mid');
  if (signal.sdpMLineIndex != null && (!Number.isSafeInteger(signal.sdpMLineIndex) || signal.sdpMLineIndex < 0 || signal.sdpMLineIndex > 65535)) throw new Error('invalid_call_mline');
  if (signal.reason != null && (!validText(signal.reason, 128))) throw new Error('invalid_call_reason');
}

export class LoomFederatedCallGateway {
  private readonly config: LoomNodeConfig;
  private readonly identity: LoomNodeIdentity;
  private readonly federation: FederationService;

  constructor(
    config: LoomNodeConfig,
    identity: LoomNodeIdentity,
    federation: FederationService,
  ) {
    this.config = config;
    this.identity = identity;
    this.federation = federation;
  }

  private allowPrivate(): boolean {
    return this.config.federationMode === 'local' || this.config.federationMode === 'hybrid';
  }

  async send(input: Omit<UnsignedFederatedCallSignal,
    'protocol' | 'eventId' | 'originNodeId' | 'originDomain' | 'destinationNodeId' | 'destinationDomain'>): Promise<void> {
    const recipient = parseLoomAddress(input.recipientAddress, this.config.publicDomain);
    if (recipient.isLocal) throw new Error('call_federation_local_recipient');
    const peer = await this.federation.discover(recipient.domain);
    if (!peerAllowed(this.config, peer)) throw new Error('federation_peer_not_trusted');

    const info = this.identity.publicInfo();
    const unsigned: UnsignedFederatedCallSignal = {
      protocol: CALL_FEDERATION_PROTOCOL,
      eventId: `fcallsig_${randomUUID()}`,
      originNodeId: info.nodeId,
      originDomain: normalizeLoomDomain(this.config.publicDomain),
      destinationNodeId: peer.nodeId,
      destinationDomain: normalizeLoomDomain(peer.domain),
      ...input,
      senderAddress: parseLoomAddress(input.senderAddress, this.config.publicDomain).canonical,
      recipientAddress: recipient.canonical,
      createdAt: new Date(input.createdAt).toISOString(),
    };
    const envelope: FederatedCallSignal = {
      ...unsigned,
      signature: this.identity.signUtf8(canonicalPayload(unsigned)),
    };
    validateSignalFields(envelope);

    const response = await safeFederationHttpsRequest(`${peer.endpoint}/federation/v1/calls/signal`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', accept: 'application/json' },
      body: JSON.stringify(envelope),
      timeoutMs: 8_000,
      maxBytes: 64 * 1024,
      allowPrivate: this.allowPrivate(),
    });
    if (response.status < 200 || response.status >= 300) {
      throw new Error(`federation_call_signal_http_${response.status}`);
    }
  }

  async verifyInbound(input: FederatedCallSignal): Promise<FederatedCallSignal> {
    validateSignalFields(input);
    const recipient = parseLoomAddress(input.recipientAddress, this.config.publicDomain);
    if (!recipient.isLocal || normalizeLoomDomain(input.destinationDomain) !== normalizeLoomDomain(this.config.publicDomain)) {
      throw new Error('call_federation_wrong_destination');
    }
    if (input.destinationNodeId !== this.identity.publicInfo().nodeId) throw new Error('call_federation_wrong_node');

    const sender = parseLoomAddress(input.senderAddress);
    if (sender.domain !== normalizeLoomDomain(input.originDomain)) throw new Error('call_federation_sender_origin_mismatch');
    const peer = await this.federation.discover(sender.domain);
    if (peer.nodeId !== input.originNodeId || !peerAllowed(this.config, peer)) throw new Error('federation_peer_not_allowed');

    const unsigned = { ...input } as FederatedCallSignal;
    delete (unsigned as Partial<FederatedCallSignal>).signature;
    if (!LoomNodeIdentity.verifyUtf8(canonicalPayload(unsigned), input.signature, peer.publicKey)) {
      throw new Error('invalid_call_federation_signature');
    }

    // Resolve through the verified Home-Node federation path and bind the
    // advertised identity to the canonical address before local delivery.
    const resolved = await this.federation.resolveUser(sender.canonical, input.kind === 'call.offer');
    if (resolved.identity.identityId !== input.senderIdentityId) throw new Error('call_sender_identity_mismatch');
    return input;
  }
}
