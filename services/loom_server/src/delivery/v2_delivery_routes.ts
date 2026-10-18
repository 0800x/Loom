import { RateLimitError } from '../security/rate_limiter.ts';
import type { IncomingMessage, ServerResponse } from 'node:http';
import type { SessionInfo } from '../storage/sqlite_store.ts';
import type { DeviceBundleStore } from '../security/device_bundle_store.ts';
import { json, readJson } from '../http/http.ts';
import { verifyV2DirectTransportProof } from './v2_direct_auth.ts';
import { V2DirectDeliveryStore } from './v2_direct_delivery_store.ts';
import { V2DeliveryStore, type V2DeliveryPacketRecord } from './v2_delivery_store.ts';
import { V2PrekeyPool } from './v2_prekey_pool.ts';
import {
  parseProximityGatewayLease,
  verifyGatewayTransportProof,
  verifyRecipientSignedProximityLease,
} from './v2_proximity_gateway_auth.ts';
import { verifyRecipientDeliveryReceipt } from './v2_proximity_delivery_receipt_auth.ts';
import { V2ProximityGatewayStore } from './v2_proximity_gateway_store.ts';
import { V2LegacyGatewayBridgeStore } from './v2_legacy_gateway_bridge_store.ts';

type Authenticate = (request: IncomingMessage) => Promise<SessionInfo | null>;

function statusForV2Error(code: string): number {
  if (code === 'body_too_large') return 413;
  if (code === 'packet_quota_exceeded') return 429;
  if (
    code === 'prekey_unavailable' ||
    code === 'mailbox_unavailable' ||
    code === 'packet_not_found' ||
    code === 'gateway_lease_unavailable'
  ) return 404;
  if (
    code === 'device_not_authorized' ||
    code === 'mailbox_not_owned' ||
    code === 'device_request_session_mismatch' ||
    code === 'gateway_recipient_device_unknown'
  ) return 403;
  if (
    code === 'device_key_bundle_required' ||
    code === 'stale_device_request' ||
    code === 'stale_direct_transport_proof' ||
    code === 'invalid_direct_transport_signature' ||
    code === 'stale_gateway_lease' ||
    code === 'stale_gateway_transport_proof' ||
    code === 'stale_gateway_recipient_receipt' ||
    code === 'gateway_proof_replay' ||
    code.startsWith('device_request_') ||
    code.startsWith('invalid_device_request_') ||
    code.startsWith('invalid_direct_') ||
    code.startsWith('invalid_gateway_')
  ) return 401;
  if (
    code === 'mailbox_token_in_use' ||
    code === 'packet_id_conflict' ||
    code === 'prekey_claim_conflict' ||
    code === 'prekey_id_conflict' ||
    code === 'gateway_lease_id_conflict'
  ) return 409;
  if (
    code === 'content_type' ||
    code === 'json_object_required' ||
    code.startsWith('invalid_') ||
    code.startsWith('duplicate_')
  ) return 400;
  return 500;
}

function mergePackets(
  local: V2DeliveryPacketRecord[],
  direct: V2DeliveryPacketRecord[],
  limitInput: unknown,
): V2DeliveryPacketRecord[] {
  const limit = typeof limitInput === 'number' && Number.isInteger(limitInput)
    ? limitInput
    : 50;
  const unique = new Map<string, V2DeliveryPacketRecord>();
  for (const packet of [...local, ...direct]) {
    if (!unique.has(packet.packetId)) unique.set(packet.packetId, packet);
  }
  return [...unique.values()]
    .sort((left, right) => {
      if (left.priority !== right.priority) return left.priority === 'urgent' ? -1 : 1;
      const accepted = left.acceptedAt.localeCompare(right.acceptedAt);
      return accepted !== 0 ? accepted : left.packetId.localeCompare(right.packetId);
    })
    .slice(0, limit);
}

export class V2DeliveryRoutes {
  private readonly store: V2DeliveryStore;
  private readonly directStore: V2DirectDeliveryStore;
  private readonly prekeyPool: V2PrekeyPool;
  private readonly gatewayStore: V2ProximityGatewayStore;
  private readonly legacyGatewayStore: V2LegacyGatewayBridgeStore;
  private readonly deviceBundles: DeviceBundleStore;
  private readonly maxRequestBytes: number;

  constructor(
    store: V2DeliveryStore,
    directStore: V2DirectDeliveryStore,
    prekeyPool: V2PrekeyPool,
    gatewayStore: V2ProximityGatewayStore,
    legacyGatewayStore: V2LegacyGatewayBridgeStore,
    deviceBundles: DeviceBundleStore,
    maxRequestBytes: number,
  ) {
    this.store = store;
    this.directStore = directStore;
    this.prekeyPool = prekeyPool;
    this.gatewayStore = gatewayStore;
    this.legacyGatewayStore = legacyGatewayStore;
    this.deviceBundles = deviceBundles;
    this.maxRequestBytes = maxRequestBytes;
  }

  async tryHandle(
    method: string,
    url: URL,
    request: IncomingMessage,
    response: ServerResponse,
    authenticate: Authenticate,
  ): Promise<boolean> {
    if (!url.pathname.startsWith('/api/v2/')) return false;

    try {
      if (method === 'GET' && url.pathname === '/api/v2/server/info') {
        json(response, 200, {
          schemaVersion: 2,
          protocolVersion: 'loom-delivery-v2',
          capabilities: [
            'opaque-packet-mailboxes',
            'one-time-opaque-prekeys',
            'fallback-opaque-prekeys',
            'idempotent-packet-enqueue',
            'mailbox-transfer-ack',
            'direct-destination-node-ingress',
            'self-certifying-device-transport-proof',
            'recipient-authorized-proximity-gateway',
            'internet-to-nearby-last-mile',
            'legacy-message-last-mile-bridge',
          ],
          packetContentVisibleToServer: false,
          recipientDeliveryReceiptEndToEnd: true,
          directIngressRequiresHomeNodeRoundTrip: false,
          proximityGatewayDeletesRecipientMailboxPacket: false,
        });
        return true;
      }

      if (method === 'POST' && url.pathname === '/api/v2/packets/direct') {
        const body = await readJson(request, this.maxRequestBytes);
        const senderTransportFingerprint = verifyV2DirectTransportProof(
          body,
          body.transportProof,
        );
        const result = await this.directStore.enqueuePacket(
          senderTransportFingerprint,
          body,
        );
        json(response, result.idempotent ? 200 : 202, {
          packetId: result.packetId,
          acceptedAt: result.acceptedAt,
          accepted: true,
          idempotent: result.idempotent,
          receiptType: 'destination_node_custody',
          recipientDeliveryConfirmed: false,
        });
        return true;
      }

      if (method === 'POST' && url.pathname === '/api/v2/gateway/leases/register') {
        const body = await readJson(request, Math.min(this.maxRequestBytes, 128 * 1024));
        const parsed = parseProximityGatewayLease(body.lease);
        const bundles = await this.deviceBundles.listForIdentity(parsed.recipientIdentityId);
        const recipient = bundles.find((bundle) => bundle.deviceId === parsed.recipientDeviceId);
        if (!recipient) throw new Error('gateway_recipient_device_unknown');
        const lease = verifyRecipientSignedProximityLease(
          body.lease,
          recipient.signingPublicKey,
        );
        const proof = verifyGatewayTransportProof(
          'register',
          {
            leaseId: lease.leaseId,
            recipientDeviceId: lease.recipientDeviceId,
          },
          body.gatewayProof,
        );
        if (
          proof.publicKey !== lease.gatewayDevicePublicKey ||
          proof.fingerprint !== lease.gatewayFingerprint
        ) throw new Error('invalid_gateway_lease_holder');
        if (!await this.gatewayStore.rememberNonce(
          proof.fingerprint,
          proof.nonce,
          new Date(Date.now() + 5 * 60_000),
        )) throw new Error('gateway_proof_replay');
        await this.gatewayStore.registerLease(lease);
        json(response, 201, {
          registered: true,
          leaseId: lease.leaseId,
          recipientDeviceId: lease.recipientDeviceId,
          expiresAt: lease.expiresAt,
          bearer: lease.bearer,
        });
        return true;
      }

      if (method === 'POST' && url.pathname === '/api/v2/gateway/claim') {
        const body = await readJson(request, Math.min(this.maxRequestBytes, 128 * 1024));
        const requestedLimit = body.limit ?? 20;
        const context = {
          leaseId: body.leaseId,
          recipientDeviceId: body.recipientDeviceId,
          limit: requestedLimit,
        };
        const proof = verifyGatewayTransportProof('claim', context, body.gatewayProof);
        if (!await this.gatewayStore.rememberNonce(
          proof.fingerprint,
          proof.nonce,
          new Date(Date.now() + 5 * 60_000),
        )) throw new Error('gateway_proof_replay');
        const lease = await this.gatewayStore.activeLease(
          body.leaseId,
          body.recipientDeviceId,
          proof.fingerprint,
        );
        const limit = Math.min(
          Number(requestedLimit),
          Number(lease.max_packets),
          50,
        );
        if (!Number.isInteger(limit) || limit < 1) {
          throw new Error('invalid_gateway_packet_limit');
        }
        const maxBytes = Number(lease.max_bytes);

        const legacyDeliveries = await this.legacyGatewayStore.claimRecentMessages(
          String(lease.recipient_device_id),
          String(lease.lease_id),
          limit,
          maxBytes,
        );
        let usedBytes = legacyDeliveries.reduce(
          (sum, item) => sum + Buffer.byteLength(JSON.stringify(item), 'utf8'),
          0,
        );
        const remainingLimit = Math.max(0, limit - legacyDeliveries.length);
        const v2Candidates = remainingLimit > 0
          ? await this.gatewayStore.claimPackets(
              body.leaseId,
              body.recipientDeviceId,
              proof.fingerprint,
              remainingLimit,
            )
          : [];
        const packets: V2DeliveryPacketRecord[] = [];
        for (const packet of v2Candidates) {
          const size = Buffer.from(packet.envelopeBase64, 'base64url').length;
          if (usedBytes + size > maxBytes) break;
          usedBytes += size;
          packets.push(packet);
        }

        json(response, 200, {
          leaseId: body.leaseId,
          recipientDeviceId: body.recipientDeviceId,
          packets,
          legacyDeliveries,
          receiptType: 'gateway_offer',
          recipientDeliveryConfirmed: false,
        });
        return true;
      }

      if (method === 'POST' && url.pathname === '/api/v2/gateway/custody') {
        const body = await readJson(request, Math.min(this.maxRequestBytes, 128 * 1024));
        const context = {
          leaseId: body.leaseId,
          recipientDeviceId: body.recipientDeviceId,
          packetIds: body.packetIds,
        };
        const proof = verifyGatewayTransportProof('custody', context, body.gatewayProof);
        if (!await this.gatewayStore.rememberNonce(
          proof.fingerprint,
          proof.nonce,
          new Date(Date.now() + 5 * 60_000),
        )) throw new Error('gateway_proof_replay');
        const activeLease = await this.gatewayStore.activeLease(
          body.leaseId,
          body.recipientDeviceId,
          proof.fingerprint,
        );
        const receiptInputs = body.recipientDeliveryReceipts == null
          ? []
          : body.recipientDeliveryReceipts;
        if (!Array.isArray(receiptInputs) || receiptInputs.length > 50) {
          throw new Error('invalid_gateway_recipient_receipt_batch');
        }
        const packetIds = Array.isArray(body.packetIds)
          ? body.packetIds.map(String)
          : [];
        const packetIdSet = new Set(packetIds);
        const verifiedDeliveryIds: string[] = [];
        if (receiptInputs.length > 0) {
          const bundles = await this.deviceBundles.listForIdentity(
            String(activeLease.recipient_identity_id),
          );
          const recipient = bundles.find(
            (bundle) => bundle.deviceId === String(activeLease.recipient_device_id),
          );
          if (!recipient) throw new Error('gateway_recipient_device_unknown');
          const seenReceipts = new Set<string>();
          for (const receiptInput of receiptInputs) {
            const receipt = verifyRecipientDeliveryReceipt(
              receiptInput,
              String(activeLease.lease_id),
              String(activeLease.recipient_device_id),
              recipient.signingPublicKey,
            );
            if (
              !packetIdSet.has(receipt.deliveryId) ||
              !seenReceipts.add(receipt.deliveryId)
            ) throw new Error('invalid_gateway_recipient_receipt_binding');
            verifiedDeliveryIds.push(receipt.deliveryId);
          }
        }
        const accepted = await this.gatewayStore.acknowledgeCustody(
          body.leaseId,
          body.recipientDeviceId,
          proof.fingerprint,
          body.packetIds,
        );
        const delivered = await this.legacyGatewayStore.emitRecipientDeliveredReceipts(
          verifiedDeliveryIds,
        );
        json(response, 200, {
          leaseId: body.leaseId,
          accepted,
          receiptType: 'gateway_custody',
          recipientDeliveryConfirmed:
            verifiedDeliveryIds.length > 0 && delivered >= 0,
          legacyDeliveredReceiptsEmitted: delivered,
          originalMailboxPacketRetained: true,
        });
        return true;
      }

      const session = await authenticate(request);
      if (!session) {
        json(response, 401, { error: 'unauthorized' });
        return true;
      }

      if (method === 'PUT' && url.pathname === '/api/v2/mailboxes') {
        const body = await readJson(request, this.maxRequestBytes);
        const mailbox = await this.store.registerMailbox(
          session.accountId,
          session.deviceId,
          body.mailboxToken,
          body.expiresAt,
        );
        json(response, 200, {
          mailboxToken: mailbox.token,
          expiresAt: mailbox.expiresAt,
        });
        return true;
      }

      if (method === 'PUT' && url.pathname === '/api/v2/prekeys') {
        const body = await readJson(request, this.maxRequestBytes);
        const result = await this.prekeyPool.publish(
          session.accountId,
          session.deviceId,
          body.prekeys,
        );
        json(response, 200, result);
        return true;
      }

      if (method === 'POST' && url.pathname === '/api/v2/prekeys/claim') {
        const body = await readJson(request, this.maxRequestBytes);
        const prekey = await this.prekeyPool.claim(body.deviceId);
        if (!prekey) {
          json(response, 404, { error: 'prekey_unavailable' });
          return true;
        }
        json(response, 200, {
          deviceId: prekey.deviceId,
          prekeyId: prekey.prekeyId,
          keyKind: prekey.keyKind,
          bundleBase64: prekey.bundleBase64,
          expiresAt: prekey.expiresAt,
        });
        return true;
      }

      if (method === 'POST' && url.pathname === '/api/v2/packets') {
        const body = await readJson(request, this.maxRequestBytes);
        const result = await this.store.enqueuePacket(
          session.accountId,
          session.deviceId,
          body,
        );
        json(response, result.idempotent ? 200 : 202, {
          packetId: result.packetId,
          acceptedAt: result.acceptedAt,
          accepted: true,
          idempotent: result.idempotent,
          receiptType: 'relay_acceptance',
        });
        return true;
      }

      if (method === 'POST' && url.pathname === '/api/v2/packets/pull') {
        const body = await readJson(request, this.maxRequestBytes);
        const localPackets = await this.store.pullPackets(
          session.accountId,
          session.deviceId,
          body.mailboxToken,
          body.limit,
        );
        const directPackets = await this.directStore.pullPackets(
          session.accountId,
          session.deviceId,
          body.mailboxToken,
          body.limit,
        );
        json(response, 200, {
          packets: mergePackets(localPackets, directPackets, body.limit),
        });
        return true;
      }

      const ack = /^\/api\/v2\/packets\/([^/]+)\/ack$/.exec(url.pathname);
      if (method === 'POST' && ack) {
        const packetId = decodeURIComponent(ack[1]);
        const acknowledged = await this.store.acknowledgePacket(
          session.accountId,
          session.deviceId,
          packetId,
        ) || await this.directStore.acknowledgePacket(
          session.accountId,
          session.deviceId,
          packetId,
        );
        if (!acknowledged) {
          json(response, 404, { error: 'packet_not_found' });
          return true;
        }
        json(response, 200, {
          packetId,
          acknowledged: true,
          receiptType: 'mailbox_transfer_ack',
          recipientDeliveryConfirmed: false,
        });
        return true;
      }

      json(response, 404, { error: 'not_found' });
      return true;
    } catch (error: unknown) {
      if (error instanceof RateLimitError) throw error;
      const code = error instanceof Error ? error.message : 'internal_error';
      const status = statusForV2Error(code);
      if (status === 500) {
        console.error('[loom-node] v2 delivery request failed', error);
      }
      json(response, status, {
        error: status === 500 ? 'internal_error' : code,
      });
      return true;
    }
  }
}
