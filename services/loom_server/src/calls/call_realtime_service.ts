import { LoomRateLimiter } from '../security/rate_limiter.ts';
import { requireCallPolicy } from './call_policy.ts';
import { validCallSdp } from './sdp.ts';
import type { WebSocket } from 'ws';

import type { LoomNodeConfig } from '../config/config.ts';
import { parseLoomAddress } from '../federation/address.ts';
import { FederationService } from '../federation/service.ts';
import type { SessionInfo } from '../storage/sqlite_store.ts';
import { LoomFederatedCallGateway, type FederatedCallSignal } from './federated_call_signal.ts';
import type { LoomCallPushGateway } from './call_push_gateway.ts';

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
const PENDING_CALL_TTL_MS = 45_000;
const MAX_FRAME_BYTES = 768 * 1024;
const MAX_QUEUED_BYTES = 4 * 1024 * 1024;
const MAX_QUEUED_FRAMES = 256;
const MAX_PENDING_ICE = 256;

type ConversationRecord = {
  id?: unknown;
  kind?: unknown;
  peerAddress?: unknown;
  peer_address?: unknown;
};

type ClientSignal = {
  kind: string;
  callId: string;
  conversationId: string;
  targetIdentityId: string;
  sequence: number;
  mediaKind?: 'audio' | 'video';
  sdp?: string;
  sdpType?: string;
  candidate?: string;
  sdpMid?: string;
  sdpMLineIndex?: number;
  reason?: string;
};

type DeliveredSignal = ClientSignal & {
  senderIdentityId: string;
  senderAddress: string;
  senderDisplayName: string;
  createdAt: string;
};

type Connection = {
  socket: WebSocket;
  session: SessionInfo;
  connectedAt: number;
  alive: boolean;
  delivery: Promise<void>;
  queuedDeliveries: number;
};

type PendingOffer = DeliveredSignal & {
  targetAddress: string;
  targetIdentityId: string;
  originNodeId: string;
  expiresAt: number;
  ice: DeliveredSignal[];
};

function safeString(value: unknown, max: number): string | null {
  if (typeof value !== 'string' || value.length < 1 || value.length > max || /[\r\n]/.test(value)) return null;
  return value;
}

function parseClientSignal(data: unknown): ClientSignal | null {
  if (typeof data !== 'string' || Buffer.byteLength(data, 'utf8') > MAX_FRAME_BYTES) return null;
  let raw: Record<string, unknown>;
  try {
    const decoded = JSON.parse(data);
    if (!decoded || typeof decoded !== 'object' || Array.isArray(decoded)) return null;
    raw = decoded as Record<string, unknown>;
  } catch {
    return null;
  }

  const kind = safeString(raw.kind, 64);
  const callId = safeString(raw.callId, 200);
  const conversationId = safeString(raw.conversationId, 256);
  const targetIdentityId = safeString(raw.targetIdentityId, 128);
  const sequence = raw.sequence;
  if (!kind || !SIGNAL_KINDS.has(kind) || !callId || !conversationId || !targetIdentityId ||
      !Number.isSafeInteger(sequence) || Number(sequence) < 0) return null;

  const mediaKind = raw.mediaKind == null ? undefined : raw.mediaKind;
  if (mediaKind != null && mediaKind !== 'audio' && mediaKind !== 'video') return null;
  const sdp = raw.sdp == null ? undefined : validCallSdp(raw.sdp) ? raw.sdp : null;
  if (raw.sdp != null && !sdp) return null;
  const sdpType = raw.sdpType == null ? undefined : safeString(raw.sdpType, 16);
  if (sdpType != null && sdpType !== 'offer' && sdpType !== 'answer') return null;
  const candidate = raw.candidate == null ? undefined : safeString(raw.candidate, 16 * 1024);
  if (raw.candidate != null && !candidate) return null;
  const sdpMid = raw.sdpMid == null ? undefined : safeString(raw.sdpMid, 256);
  if (raw.sdpMid != null && !sdpMid) return null;
  const sdpMLineIndex = raw.sdpMLineIndex == null ? undefined : raw.sdpMLineIndex;
  if (sdpMLineIndex != null && (!Number.isSafeInteger(sdpMLineIndex) || Number(sdpMLineIndex) < 0 || Number(sdpMLineIndex) > 65535)) return null;
  const reason = raw.reason == null ? undefined : safeString(raw.reason, 128);
  if (raw.reason != null && !reason) return null;

  if (kind === 'call.offer' && (!sdp || sdpType !== 'offer' || !mediaKind)) return null;
  if (kind === 'call.answer' && (!sdp || sdpType !== 'answer')) return null;
  if (kind === 'call.ice' && !candidate) return null;

  return {
    kind,
    callId,
    conversationId,
    targetIdentityId,
    sequence: Number(sequence),
    mediaKind: mediaKind as 'audio' | 'video' | undefined,
    sdp,
    sdpType,
    candidate,
    sdpMid,
    sdpMLineIndex: sdpMLineIndex == null ? undefined : Number(sdpMLineIndex),
    reason,
  };
}

function socketOpen(socket: WebSocket): boolean {
  return socket.readyState === 1;
}

export class LoomCallRealtimeService {
  private readonly frameLimiter = new LoomRateLimiter();
  private readonly connections = new Map<string, Set<Connection>>();
  private readonly pending = new Map<string, PendingOffer>();
  private readonly seen = new Map<string, number>();
  private readonly config: LoomNodeConfig;
  private readonly federation: FederationService;
  private readonly federatedCalls: LoomFederatedCallGateway;
  private readonly push: LoomCallPushGateway;
  private readonly listConversations: (accountId: string) => Promise<ConversationRecord[]>;
  private readonly cleanupTimer: NodeJS.Timeout;
  private readonly pingTimer: NodeJS.Timeout;
  private malformedFrames = 0;
  private routedSignals = 0;
  private federationFailures = 0;

  constructor(
    config: LoomNodeConfig,
    federation: FederationService,
    federatedCalls: LoomFederatedCallGateway,
    push: LoomCallPushGateway,
    listConversations: (accountId: string) => Promise<ConversationRecord[]>,
  ) {
    this.config = config;
    this.federation = federation;
    this.federatedCalls = federatedCalls;
    this.push = push;
    this.listConversations = listConversations;
    this.cleanupTimer = setInterval(() => this.cleanup(), 5_000);
    this.cleanupTimer.unref();
    this.pingTimer = setInterval(() => this.pingConnections(), 20_000);
    this.pingTimer.unref();
  }

  attach(session: SessionInfo, socket: WebSocket): void {
    if (!this.config.callsEnabled) {
      socket.close(1013, 'calling disabled');
      return;
    }
    const connection: Connection = { socket, session, connectedAt: Date.now(), alive: true, delivery: Promise.resolve(), queuedDeliveries: 0 };
    const set = this.connections.get(session.identityId) ?? new Set<Connection>();
    if (set.size >= 8) {socket.close(1013, 'connection limit'); return;}
    if (this.connections.size >= 2000 && !this.connections.has(session.identityId)) {socket.close(1013, 'server connection limit'); return;}
    set.add(connection);
    this.connections.set(session.identityId, set);
    // Recover immediately on a fresh/reconnected receiver socket, including
    // ICE gathered while it was away. Queue live frames behind this replay.
    void this.queueDelivery(connection, () => this.replayPending(connection));

    let accepting = true;
    let queuedBytes = 0;
    let queuedFrames = 0;
    let frames = Promise.resolve();
    socket.on('pong', () => { connection.alive = true; });
    socket.on('message', (data, binary) => {
      if (!accepting) return;
      try { this.frameLimiter.consume('call-frames', session.accountId + ':' + session.deviceId, 600); }
      catch { accepting = false; socket.close(1013, 'rate limited'); return; }
      if (binary) {
        this.malformedFrames += 1;
        return;
      }
      const text = typeof data === 'string' ? data : data.toString('utf8');
      const bytes = Buffer.byteLength(text, 'utf8');
      if (bytes > MAX_FRAME_BYTES) {
        this.malformedFrames += 1;
        return;
      }
      if (queuedBytes + bytes > MAX_QUEUED_BYTES || queuedFrames >= MAX_QUEUED_FRAMES) {
        accepting = false;
        socket.close(1013, 'signaling queue full');
        return;
      }
      queuedBytes += bytes;
      queuedFrames += 1;
      // Async profile lookup/federation must not let ICE or a hangup overtake
      // the preceding offer. Keep a bounded queue per authenticated socket.
      frames = frames.then(async () => {
        try {
          if (accepting && socketOpen(socket)) await this.handleClientFrame(connection, text);
        } finally {
          queuedBytes -= bytes;
          queuedFrames -= 1;
        }
      }).catch(() => {
        accepting = false;
        try { socket.close(1011, 'signaling unavailable'); } catch { /* socket already closed */ }
      });
    });
    const disconnect = () => { accepting = false; this.removeConnection(connection); };
    socket.on('close', disconnect);
    socket.on('error', disconnect);
  }

  async pendingFor(session: SessionInfo): Promise<Array<Record<string, unknown>>> {
    this.cleanup();
    const result: Array<Record<string, unknown>> = [];
    for (const offer of this.pending.values()) {
      if (offer.targetIdentityId !== session.identityId || offer.expiresAt <= Date.now()) continue;
      const conversationId = await this.federation.routing.ensureRemoteConversation(
        session.accountId,
        offer.senderAddress,
        offer.originNodeId,
      );
      result.push({
        callId: offer.callId,
        conversationId,
        callerIdentityId: offer.senderIdentityId,
        callerAddress: offer.senderAddress,
        callerDisplayName: offer.senderDisplayName,
        kind: offer.mediaKind,
        createdAt: offer.createdAt,
        expiresAt: new Date(offer.expiresAt).toISOString(),
        offerSdp: offer.sdp,
      });
    }
    return result.sort((a, b) => String(a.createdAt).localeCompare(String(b.createdAt)));
  }

  async acceptFederated(signal: FederatedCallSignal): Promise<void> {
    const verified = await this.federatedCalls.verifyInbound(signal);
    requireCallPolicy(this.config, verified);
    const localProfile = await this.federation.resolveUser(verified.recipientAddress, true);
    if (localProfile.identity.identityId !== verified.targetIdentityId) throw new Error('call_target_identity_mismatch');

    const delivered: DeliveredSignal = {
      kind: verified.kind,
      callId: verified.callId,
      conversationId: verified.conversationId,
      targetIdentityId: verified.targetIdentityId,
      sequence: verified.sequence,
      mediaKind: verified.mediaKind,
      sdp: verified.sdp,
      sdpType: verified.sdpType,
      candidate: verified.candidate,
      sdpMid: verified.sdpMid,
      sdpMLineIndex: verified.sdpMLineIndex,
      reason: verified.reason,
      senderIdentityId: verified.senderIdentityId,
      senderAddress: verified.senderAddress,
      senderDisplayName: verified.senderDisplayName,
      createdAt: verified.createdAt,
    };
    await this.deliverLocal(delivered, verified.originNodeId, verified.recipientAddress);
  }

  diagnostics(): Record<string, unknown> {
    let sockets = 0;
    for (const values of this.connections.values()) sockets += values.size;
    return {
      enabled: Boolean(this.config.callsEnabled),
      voiceEnabled: this.config.callsEnabled === true && this.config.voiceCallsEnabled !== false,
      videoEnabled: this.config.callsEnabled === true && this.config.videoCallsEnabled !== false,
      realtimeIdentities: this.connections.size,
      realtimeDevices: sockets,
      pendingCalls: [...this.pending.values()].filter((call) => call.expiresAt > Date.now()).length,
      malformedFrames: this.malformedFrames,
      routedSignals: this.routedSignals,
      federationFailures: this.federationFailures,
      pushAvailable: this.push.available,
    };
  }

  close(): void {
    clearInterval(this.cleanupTimer);
    clearInterval(this.pingTimer);
    for (const set of this.connections.values()) {
      for (const connection of set) {
        try { connection.socket.close(1001, 'server shutdown'); } catch { /* best effort */ }
      }
    }
    this.connections.clear();
    this.pending.clear();
  }

  private async handleClientFrame(connection: Connection, data: string): Promise<void> {
    const signal = parseClientSignal(data);
    if (!signal) {
      this.malformedFrames += 1;
      return;
    }
    const dedupeKey = `${connection.session.identityId}\n${signal.callId}\n${signal.sequence}`;
    if (this.seen.has(dedupeKey)) return;
    this.seen.set(dedupeKey, Date.now());

    try {
      requireCallPolicy(this.config, signal);
      const conversations = await this.listConversations(connection.session.accountId);
      const conversation = conversations.find((item) => String(item.id ?? '') === signal.conversationId);
      const peerAddressValue = conversation?.peerAddress ?? conversation?.peer_address;
      if (!conversation || String(conversation.kind) !== 'direct' || typeof peerAddressValue !== 'string') {
        throw new Error('call_conversation_not_found');
      }
      const peerAddress = parseLoomAddress(peerAddressValue, this.config.publicDomain).canonical;
      // Refresh identity for each offer; use the same verified profile cache
      // for its subsequent ICE/control frames instead of repeated remote I/O.
      const peer = await this.federation.resolveUser(peerAddress, signal.kind === 'call.offer');
      if (peer.identity.identityId !== signal.targetIdentityId) throw new Error('call_target_identity_mismatch');

      const sender = await this.federation.routing.resolveLocalUser(connection.session.username, this.config.publicDomain);
      if (!sender || sender.identity.identityId !== connection.session.identityId) throw new Error('call_sender_identity_mismatch');
      const delivered: DeliveredSignal = {
        ...signal,
        senderIdentityId: connection.session.identityId,
        senderAddress: sender.address,
        senderDisplayName: sender.displayName,
        createdAt: new Date().toISOString(),
      };

      if (parseLoomAddress(peerAddress, this.config.publicDomain).isLocal) {
        await this.deliverLocal(delivered, peer.homeNode.nodeId, peerAddress);
      } else {
        try {
          await this.federatedCalls.send({
            senderAddress: sender.address,
            recipientAddress: peerAddress,
            senderIdentityId: connection.session.identityId,
            targetIdentityId: signal.targetIdentityId,
            senderDisplayName: sender.displayName,
            callId: signal.callId,
            conversationId: signal.conversationId,
            kind: signal.kind,
            sequence: signal.sequence,
            createdAt: delivered.createdAt,
            mediaKind: signal.mediaKind,
            sdp: signal.sdp,
            sdpType: signal.sdpType,
            candidate: signal.candidate,
            sdpMid: signal.sdpMid,
            sdpMLineIndex: signal.sdpMLineIndex,
            reason: signal.reason,
          });
        } catch (error) {
          this.federationFailures += 1;
          throw error;
        }
      }
      this.clearAnsweredPending(delivered);
      this.routedSignals += 1;
    } catch (error) {
      // Signal errors are intentionally generic on the wire. Server logs and
      // diagnostics classify failures without SDP, ICE candidates or TURN secrets.
      this.sendError(connection.socket, signal, error);
    }
  }

  private async deliverLocal(signal: DeliveredSignal, originNodeId: string, targetAddress: string): Promise<void> {
    if (signal.kind === 'call.offer') {
      const expiresAt = Date.now() + PENDING_CALL_TTL_MS;
      const existing = this.pending.get(signal.callId);
      if (!existing || (existing.senderIdentityId === signal.senderIdentityId && existing.targetIdentityId === signal.targetIdentityId)) {
        this.pending.set(signal.callId, {
          ...signal,
          targetAddress,
          targetIdentityId: signal.targetIdentityId,
          originNodeId,
          expiresAt,
          ice: existing?.ice ?? [],
        });
      } else {
        throw new Error('call_id_conflict');
      }
    } else if (signal.kind === 'call.ice') {
      const offer = this.pending.get(signal.callId);
      if (offer && offer.senderIdentityId === signal.senderIdentityId &&
          offer.targetIdentityId === signal.targetIdentityId && offer.expiresAt > Date.now() &&
          offer.ice.length < MAX_PENDING_ICE && !offer.ice.some((item) => item.sequence === signal.sequence)) {
        offer.ice.push(signal);
      }
    }
    this.clearAnsweredPending(signal);

    const targets = this.connections.get(signal.targetIdentityId);
    let deliveredCount = 0;
    if (targets) {
      for (const target of [...targets]) {
        if (!socketOpen(target.socket)) {
          this.removeConnection(target);
          continue;
        }
        await this.queueDelivery(target, async () => {
          const localConversationId = await this.federation.routing.ensureRemoteConversation(
            target.session.accountId,
            signal.senderAddress,
            originNodeId,
          );
          if (socketOpen(target.socket)) {
            target.socket.send(JSON.stringify({ ...signal, conversationId: localConversationId }));
            deliveredCount += 1;
          }
        });
      }
    }

    if (signal.kind === 'call.offer' && deliveredCount === 0) {
      const pending = this.pending.get(signal.callId);
      if (pending) {
        await this.push.wakeIncomingCall({
          callId: signal.callId,
          conversationId: signal.conversationId,
          callerIdentityId: signal.senderIdentityId,
          callerAddress: signal.senderAddress,
          callerDisplayName: signal.senderDisplayName,
          targetIdentityId: signal.targetIdentityId,
          mediaKind: signal.mediaKind ?? 'audio',
          expiresAt: new Date(pending.expiresAt).toISOString(),
        });
      }
    }
  }

  private queueDelivery(connection: Connection, send: () => Promise<void>): Promise<void> {
    if (connection.queuedDeliveries >= MAX_QUEUED_FRAMES) {
      this.removeConnection(connection);
      try { connection.socket.close(1013, 'call delivery queue full'); } catch { /* already closed */ }
      return Promise.resolve();
    }
    connection.queuedDeliveries += 1;
    connection.delivery = connection.delivery.then(send).catch(() => {
      this.removeConnection(connection);
      try { connection.socket.close(1011, 'call delivery unavailable'); } catch { /* already closed */ }
    }).finally(() => {
      connection.queuedDeliveries -= 1;
    });
    return connection.delivery;
  }

  private async replayPending(connection: Connection): Promise<void> {
    this.cleanup();
    for (const offer of [...this.pending.values()]) {
      if (offer.targetIdentityId !== connection.session.identityId) continue;
      const conversationId = await this.federation.routing.ensureRemoteConversation(
        connection.session.accountId, offer.senderAddress, offer.originNodeId,
      );
      // A cancellation/answer may have arrived during the database lookup.
      if (!socketOpen(connection.socket) || this.pending.get(offer.callId) !== offer || offer.expiresAt <= Date.now()) continue;
      const { targetAddress: _address, originNodeId: _origin, expiresAt: _expiry, ice, ...signal } = offer;
      connection.socket.send(JSON.stringify({ ...signal, conversationId }));
      for (const candidate of ice) connection.socket.send(JSON.stringify({ ...candidate, conversationId }));
    }
  }

  private clearAnsweredPending(signal: DeliveredSignal): void {
    if (!['call.answer', 'call.reject', 'call.busy', 'call.end'].includes(signal.kind)) return;
    const offer = this.pending.get(signal.callId);
    if (!offer) return;
    const caller = offer.senderIdentityId === signal.senderIdentityId && offer.targetIdentityId === signal.targetIdentityId;
    const callee = offer.targetIdentityId === signal.senderIdentityId && offer.senderIdentityId === signal.targetIdentityId;
    if (callee || (caller && signal.kind === 'call.end')) this.pending.delete(signal.callId);
  }

  private sendError(socket: WebSocket, signal: ClientSignal, error: unknown): void {
    if (!socketOpen(socket)) return;
    const code = error instanceof Error && error.message.startsWith('call_')
      ? error.message
      : 'call_signaling_failed';
    socket.send(JSON.stringify({
      kind: 'call.error',
      callId: signal.callId,
      conversationId: signal.conversationId,
      senderIdentityId: signal.targetIdentityId,
      targetIdentityId: '',
      sequence: signal.sequence,
      createdAt: new Date().toISOString(),
      reason: code,
    }));
  }

  private removeConnection(connection: Connection): void {
    const set = this.connections.get(connection.session.identityId);
    if (!set) return;
    set.delete(connection);
    if (set.size === 0) this.connections.delete(connection.session.identityId);
  }

  private cleanup(): void {
    const now = Date.now();
    for (const [callId, offer] of this.pending.entries()) {
      if (offer.expiresAt <= now) this.pending.delete(callId);
    }
    for (const [key, timestamp] of this.seen.entries()) {
      if (timestamp < now - 5 * 60_000) this.seen.delete(key);
    }
  }

  private pingConnections(): void {
    for (const set of this.connections.values()) {
      for (const connection of [...set]) {
        if (!connection.alive || !socketOpen(connection.socket)) {
          try { connection.socket.terminate(); } catch { /* best effort */ }
          this.removeConnection(connection);
          continue;
        }
        connection.alive = false;
        try { connection.socket.ping(); } catch { this.removeConnection(connection); }
      }
    }
  }
}

