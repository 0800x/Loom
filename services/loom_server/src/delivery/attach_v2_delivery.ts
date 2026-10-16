import type { IncomingMessage, ServerResponse } from 'node:http';
import type { LoomNodeConfig } from '../config/config.ts';
import type { LoomNodeServer } from '../bootstrap/server.ts';
import type { SessionInfo } from '../storage/sqlite_store.ts';
import type { FederationService } from '../federation/service.ts';
import type { FederationRoutingStore } from '../federation/routing_store.ts';
import type { DeviceBundleStore } from '../security/device_bundle_store.ts';
import type { LoomNodeIdentity } from '../identity/node_identity.ts';
import { parseLoomAddress } from '../federation/address.ts';
import { verifyDiscovery, type FederationDiscovery } from '../federation/protocol.ts';
import {
  signFederationUserProfile,
  verifyFederationUserProfile,
  type SignedFederationUserProfile,
} from '../federation/user_protocol.ts';
import { json, readJson } from '../http/http.ts';
import { V2DirectDeliveryStore } from './v2_direct_delivery_store.ts';
import { V2DeliveryStore } from './v2_delivery_store.ts';
import { V2PrekeyPool } from './v2_prekey_pool.ts';
import { V2DeliveryRoutes } from './v2_delivery_routes.ts';
import { V2ProximityGatewayStore } from './v2_proximity_gateway_store.ts';
import { V2LegacyGatewayBridgeStore } from './v2_legacy_gateway_bridge_store.ts';
import {
  LegacyDirectMessageRoutes,
  type LegacyDirectMessagePayload,
} from './legacy_direct_message_routes.ts';

type InboundHandshakeBinding = {
  domain: string;
  nodeId: string;
  publicKey: string;
  endpoint: string;
};

type LegacyMessageStore = {
  createMessage(
    accountId: string,
    input: {
      conversationId: string;
      clientId: string;
      senderAddress: string;
      type: string;
      ciphertext: string;
      protocolVersion: string;
      replyToMessageId?: string | null;
      metadata?: unknown;
    },
  ): Record<string, unknown> | Promise<Record<string, unknown>>;
};

type ServerInternals = {
  handle(request: IncomingMessage, response: ServerResponse): Promise<void>;
  authenticated(request: IncomingMessage): Promise<SessionInfo | null>;
  identity: LoomNodeIdentity;
  deviceBundles: DeviceBundleStore;
  federationRouting: FederationRoutingStore;
  federationService: FederationService;
  store: LegacyMessageStore;
  federationHandshakeAllowed(
    request: IncomingMessage,
    input: InboundHandshakeBinding,
  ): Promise<boolean>;
  close(): Promise<void>;
};

const attached = new WeakSet<object>();

export async function attachV2DeliveryService(
  server: LoomNodeServer,
  config: LoomNodeConfig,
): Promise<void> {
  if (attached.has(server)) return;

  const store = config.mode === 'production'
    ? await V2DeliveryStore.postgresStore(config.databaseUrl!)
    : V2DeliveryStore.sqliteStore(config.dataDirectory);

  let directStore: V2DirectDeliveryStore;
  try {
    directStore = config.mode === 'production'
      ? await V2DirectDeliveryStore.postgresStore(config.databaseUrl!)
      : V2DirectDeliveryStore.sqliteStore(config.dataDirectory);
  } catch (error) {
    await store.close();
    throw error;
  }

  let prekeyPool: V2PrekeyPool;
  try {
    prekeyPool = config.mode === 'production'
      ? await V2PrekeyPool.postgresStore(config.databaseUrl!)
      : V2PrekeyPool.sqliteStore(config.dataDirectory);
  } catch (error) {
    try {
      await directStore.close();
    } finally {
      await store.close();
    }
    throw error;
  }

  let gatewayStore: V2ProximityGatewayStore;
  try {
    gatewayStore = config.mode === 'production'
      ? await V2ProximityGatewayStore.postgresStore(config.databaseUrl!)
      : V2ProximityGatewayStore.sqliteStore(config.dataDirectory);
  } catch (error) {
    try {
      await prekeyPool.close();
    } finally {
      try {
        await directStore.close();
      } finally {
        await store.close();
      }
    }
    throw error;
  }

  let legacyGatewayStore: V2LegacyGatewayBridgeStore;
  try {
    legacyGatewayStore = config.mode === 'production'
      ? await V2LegacyGatewayBridgeStore.postgresStore(config.databaseUrl!)
      : V2LegacyGatewayBridgeStore.sqliteStore(config.dataDirectory);
  } catch (error) {
    try {
      await gatewayStore.close();
    } finally {
      try {
        await prekeyPool.close();
      } finally {
        try {
          await directStore.close();
        } finally {
          await store.close();
        }
      }
    }
    throw error;
  }

  const target = server as unknown as ServerInternals;
  const routes = new V2DeliveryRoutes(
    store,
    directStore,
    prekeyPool,
    gatewayStore,
    legacyGatewayStore,
    target.deviceBundles,
    config.maxRequestBytes,
  );
  const legacyDirectMessages = new LegacyDirectMessageRoutes(
    target.deviceBundles,
    target.federationRouting,
    config.publicDomain,
    config.maxRequestBytes,
    async (session: SessionInfo, payload: LegacyDirectMessagePayload) => {
      const senderAddress = `@${session.username}:${config.publicDomain}`;
      const message = {
        conversationId: payload.conversationId,
        clientId: payload.clientId,
        senderAddress,
        type: payload.type,
        ciphertext: payload.ciphertext,
        protocolVersion: payload.protocolVersion,
        replyToMessageId: payload.replyToMessageId ?? null,
        metadata: payload.metadata,
      };
      const receipt = await target.store.createMessage(session.accountId, message);
      const deliveries = await target.federationService.routeLocalMessage({
        conversationId: message.conversationId,
        senderAddress,
        receipt,
        message: {
          messageId: String(receipt.messageId),
          clientId: message.clientId,
          type: message.type,
          ciphertext: message.ciphertext,
          protocolVersion: message.protocolVersion,
          replyToMessageId: message.replyToMessageId,
          metadata: message.metadata,
        },
      });
      return {
        ...receipt,
        federation: { queued: deliveries.length, deliveries },
      };
    },
  );
  const originalHandle = target.handle.bind(server);
  const authenticate = target.authenticated.bind(server);
  const originalClose = target.close.bind(server);

  target.federationHandshakeAllowed = async (
    _request: IncomingMessage,
    input: InboundHandshakeBinding,
  ): Promise<boolean> => {
    try {
      await target.federationService.peerForInbound({
        domain: input.domain,
        nodeId: input.nodeId,
        publicKey: input.publicKey,
        endpoint: input.endpoint,
      });
      return true;
    } catch {
      return false;
    }
  };

  target.federationService.createRemoteConversation = async (
    accountId: string,
    addressValue: string,
  ) => {
    const address = parseLoomAddress(addressValue, config.publicDomain);
    const profile = await target.federationService.resolveUser(
      address.canonical,
      false,
    );
    const conversationId = await target.federationService.routing.ensureRemoteConversation(
      accountId,
      address.canonical,
      profile.homeNode.nodeId,
    );
    return { conversationId, peerAddress: address.canonical, profile };
  };

  target.handle = async (request: IncomingMessage, response: ServerResponse): Promise<void> => {
    const method = request.method ?? 'GET';
    const url = new URL(request.url ?? '/', `http://${request.headers.host ?? 'localhost'}`);

    if (method === 'POST' && url.pathname === '/api/v2/users/resolve') {
      try {
        const body = await readJson(request, Math.min(config.maxRequestBytes, 64 * 1024));
        const address = parseLoomAddress(String(body.address ?? ''), config.publicDomain);
        if (!address.isLocal) {
          json(response, 404, { error: 'user_not_found' });
          return;
        }
        const profile = await target.federationRouting.resolveLocalUser(
          address.username,
          address.domain,
        );
        if (!profile) {
          json(response, 404, { error: 'user_not_found' });
          return;
        }
        profile.homeNode.nodeId = target.identity.publicInfo().nodeId;
        const devices = await target.deviceBundles.listForIdentity(
          profile.identity.identityId,
        );
        json(
          response,
          200,
          signFederationUserProfile(target.identity, { ...profile, devices }),
        );
      } catch (error) {
        const code = error instanceof Error ? error.message : 'internal_error';
        const badRequest =
          code === 'body_too_large' ||
          code === 'content_type' ||
          code === 'json_object_required' ||
          code.startsWith('invalid_');
        if (!badRequest) {
          console.error('[loom-node] direct user resolution failed', error);
        }
        json(response, badRequest ? 400 : 500, {
          error: badRequest ? code : 'internal_error',
        });
      }
      return;
    }

    if (method === 'POST' && url.pathname === '/api/v2/users/cache-verified') {
      try {
        const session = await authenticate(request);
        if (!session) {
          json(response, 401, { error: 'unauthorized' });
          return;
        }
        const body = await readJson(request, Math.min(config.maxRequestBytes, 512 * 1024));
        const discovery = body.discovery as FederationDiscovery;
        const signedProfile = body.profile as SignedFederationUserProfile;
        const verifiedNode = verifyDiscovery(discovery);
        const parsedAddress = parseLoomAddress(String(signedProfile?.address ?? ''));
        if (parsedAddress.domain !== verifiedNode.domain) {
          throw new Error('federation_user_home_node_mismatch');
        }
        const profile = verifyFederationUserProfile(
          signedProfile,
          verifiedNode.publicKey,
          {
            address: parsedAddress.canonical,
            nodeId: verifiedNode.nodeId,
            domain: verifiedNode.domain,
          },
        );
        const peer = await target.federationService.nodes.upsert({
          nodeId: verifiedNode.nodeId,
          domain: verifiedNode.domain,
          endpoint: verifiedNode.endpoint,
          publicKey: verifiedNode.publicKey,
          fingerprint: verifiedNode.fingerprint,
          protocolVersion: discovery.protocol,
          latencyMs: 0,
        });
        if (peer.trustState === 'blocked') {
          json(response, 403, { error: 'federation_node_blocked' });
          return;
        }
        await target.federationService.routing.cacheRemoteUser(profile);
        json(response, 200, {
          cached: true,
          address: profile.address,
          nodeId: peer.nodeId,
        });
      } catch (error) {
        const code = error instanceof Error ? error.message : 'internal_error';
        const clientError =
          code.startsWith('invalid_') ||
          code.startsWith('unsupported_') ||
          code.startsWith('federation_') ||
          code === 'body_too_large' ||
          code === 'content_type' ||
          code === 'json_object_required';
        if (!clientError) {
          console.error('[loom-node] verified user cache import failed', error);
        }
        json(response, clientError ? 400 : 500, {
          error: clientError ? code : 'internal_error',
        });
      }
      return;
    }

    if (await legacyDirectMessages.tryHandle(method, url, request, response)) return;
    if (await routes.tryHandle(method, url, request, response, authenticate)) return;
    await originalHandle(request, response);
  };

  target.close = async (): Promise<void> => {
    try {
      await legacyGatewayStore.close();
    } finally {
      try {
        await gatewayStore.close();
      } finally {
        try {
          await prekeyPool.close();
        } finally {
          try {
            await directStore.close();
          } finally {
            try {
              await store.close();
            } finally {
              await originalClose();
            }
          }
        }
      }
    }
  };

  attached.add(server);
}
