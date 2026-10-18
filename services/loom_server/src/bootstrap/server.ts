import { GroupCallService } from '../calls/group_call_service.ts';
import { GroupCallGateway } from '../calls/group_call_gateway.ts';
import { GroupStore, GroupError } from '../groups/group_store.ts';
import { LoomRateLimiter, RateLimitError, endpointClass } from '../security/rate_limiter.ts';
import { serveEncryptedAttachment } from '../attachments/download.ts';
import { LocalRoutingWorker } from '../messaging/local_routing_worker.ts';
import { validateProfileUpdate } from '../profile/profile.ts';
import { createServer, type IncomingMessage, type Server, type ServerResponse } from 'node:http';
import { timingSafeEqual } from 'node:crypto';
import { runningBuildCommit, serverVersion } from '../build_info.ts';
import type { Duplex } from 'node:stream';
import { WebSocketServer } from 'ws';
import { LoomAccountRealtimeService } from '../messaging/account_realtime_service.ts';
import type { LoomNodeConfig } from '../config/config.ts';
import { SqliteStore, type SessionInfo } from '../storage/sqlite_store.ts';
import { PostgresStore } from '../storage/postgres_store.ts';
import { LoomNodeIdentity } from '../identity/node_identity.ts';
import { validateIdentityPublicMaterial } from '../identity/public_material.ts';
import { DeviceBundleStore } from '../security/device_bundle_store.ts';
import { DeviceRequestVerifier } from '../security/device_request_proof.ts';
import { DeviceLinkStore } from '../security/device_link_store.ts';
import { FilesystemAttachmentStore } from '../attachments/filesystem_store.ts';
import { S3AttachmentStore } from '../attachments/s3_store.ts';
import { RegistrationApprovalStore } from '../registration/approval_store.ts';
import { FederationPeerStore } from '../federation/peer_store.ts';
import { FederationNodeRegistry } from '../federation/node_registry.ts';
import { FederationRoutingStore } from '../federation/routing_store.ts';
import { FederationService } from '../federation/service.ts';
import { createHandshakeResponse, isPrivateOrLocalAddress, validateHandshake, type FederationHandshake } from '../federation/protocol.ts';
import { parseLoomAddress } from '../federation/address.ts';
import { signFederationUserProfile } from '../federation/user_protocol.ts';
import type { FederationEnvelope } from '../federation/event.ts';
import { bearerToken, json, readJson, text } from '../http/http.ts';
import { landingPage, nodeStatusScript, type PublicNodeStatus } from '../http/landing_page.ts';
import { publicAssets } from '../http/public_assets.ts';
import QRCode from 'qrcode';
import { LoomLanDiscoveryResponder } from '../lan/lan_discovery.ts';
import { buildRtcConfiguration, rtcReady } from '../calls/rtc_config.ts';
import { DisabledLoomCallPushGateway } from '../calls/call_push_gateway.ts';
import { LoomFederatedCallGateway, type FederatedCallSignal } from '../calls/federated_call_signal.ts';
import { LoomCallRealtimeService } from '../calls/call_realtime_service.ts';

function safeEqualUtf8(a: string, b: string): boolean {
  const aa = Buffer.from(a);
  const bb = Buffer.from(b);
  return aa.length === bb.length && timingSafeEqual(aa, bb);
}

function publicServerInfo(config: LoomNodeConfig, identity: LoomNodeIdentity): Record<string, unknown> {
  const key = identity.publicInfo();
  const calling = config.callsEnabled === true;
  return {
    schemaVersion: 1,
    serverVersion,
    protocolVersion: 'loom-node-v1',
    nodeId: key.nodeId,
    name: config.operatorName === 'Private operator' ? `Loom Node — ${config.publicDomain}` : config.operatorName,
    domain: config.publicDomain,
    endpoint: config.publicBaseUrl,
    publicKey: key.publicKey,
    fingerprint: key.fingerprint,
    limits: { maxAttachmentBytes: config.maxAttachmentBytes, maxMediaBytes: config.maxAttachmentBytes - 28, maxRequestBytes: config.maxRequestBytes },
    registration: config.registrationPolicy,
    federation: config.federationMode !== 'disabled',
    federationMode: config.federationMode,
    networkJurisdiction: config.networkJurisdiction,
    protocol: [
      'Loom-Identity-v1',
      'loom-sync-v1',
      'loom-federation-v1',
      'loom-device-request-v1',
      'loom-device-link-v1',
      'Loom-MLS-v1',
      ifValue(calling, 'loom-call-signaling-v1'),
    ].filter(Boolean),
    capabilities: [
      'identity-registration',
      'registration-approval',
      'opaque-messaging',
      'mls-groups-home-node',
      'public-profile-sync',
      'attachments',
      'device-key-bundles',
      'device-bound-auth',
      'password-device-bootstrap',
      'short-lived-device-link',
      'federation-discovery',
      'federation-handshake',
      'federation-user-resolution',
      'federation-routing',
      'federation-outbox',
      'federation-inbox',
      ifValue(config.callsEnabled && config.voiceCallsEnabled !== false && config.groupCalls?.enabled, 'mls-encrypted-group-calls'),
      ifValue(calling, 'webrtc-1to1-calls'),
      ifValue(calling && config.voiceCallsEnabled !== false, 'voice-calls'),
      ifValue(calling && config.videoCallsEnabled !== false, 'video-calls'),
      ifValue(calling, 'webrtc-dtls-srtp'),
      ifValue(calling, 'rtc-short-lived-turn'),
      ifValue(calling && config.federationMode !== 'disabled', 'federated-call-signaling'),
    ].filter(Boolean),
  };
}

function ifValue(condition: boolean, value: string): string | null {
  return condition ? value : null;
}

function wellKnownServer(config: LoomNodeConfig, identity: LoomNodeIdentity): Record<string, unknown> {
  const key = identity.publicInfo();
  const protocol = 'loom-federation-v1';
  const payload = `${config.publicDomain}\n${protocol}\n${config.publicBaseUrl}\n${key.nodeId}\n${key.publicKey}`;
  return {
    endpoint: config.publicBaseUrl,
    nodeId: key.nodeId,
    protocol,
    publicKey: key.publicKey,
    signature: identity.signUtf8(payload),
  };
}

function requireRegistrationIdentity(body: Record<string, unknown>): void {
  const value = body.identity;
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('invalid_identity');
  const identity = value as Record<string, unknown>;
  validateIdentityPublicMaterial({
    identityId: String(identity.identityId ?? ''),
    publicKey: String(identity.publicKey ?? ''),
    fingerprint: String(identity.fingerprint ?? ''),
  });
}

export class LoomNodeServer {
  private readonly limiter = new LoomRateLimiter();
  private publicSnapshot?: Promise<PublicNodeStatus>;
  private publicSnapshotAt = 0;
  private publicQr?: Promise<string>;

  private shareUrl(): string {
    const key = this.identity.publicInfo();
    const url = new URL('/', this.config.publicBaseUrl);
    url.searchParams.set('loom-node', '1');
    url.searchParams.set('nodeId', key.nodeId);
    url.searchParams.set('fingerprint', key.fingerprint);
    return url.toString();
  }

  private publicStatus(): Promise<PublicNodeStatus> {
    if (this.publicSnapshot && Date.now() - this.publicSnapshotAt < 15_000) return this.publicSnapshot;
    this.publicSnapshotAt = Date.now();
    this.publicSnapshot = (async () => {
      let accounts: number | null = null, databaseReady = false;
      try { accounts = await this.store.publicAccountCount(); databaseReady = true; } catch { /* unavailable is distinct from zero */ }
      const storage = await this.attachments.health().catch(() => ({ ready: false }));
      return {
        status: databaseReady && storage.ready ? 'operational' : 'degraded',
        usersRegistered: accounts,
        usersConnected: this.accountRealtime.connectedAccountCount(),
        uptimeSeconds: Math.floor(process.uptime()),
        sampledAt: new Date().toISOString(),
        ...(this.config.publicResourceMetrics ? { resources: { processRssBytes: process.memoryUsage().rss, processHeapBytes: process.memoryUsage().heapUsed } } : {}),
      };
    })();
    return this.publicSnapshot;
  }
  readonly config: LoomNodeConfig;
  private readonly store: SqliteStore | PostgresStore;
  private readonly identity: LoomNodeIdentity;
  private readonly groups: GroupStore;
  private readonly groupCalls: GroupCallService;
  private readonly groupCallGateway: GroupCallGateway;
  private readonly deviceBundles: DeviceBundleStore;
  private readonly deviceRequests: DeviceRequestVerifier;
  private readonly deviceLinks = new DeviceLinkStore();
  private readonly attachments: FilesystemAttachmentStore | S3AttachmentStore;
  private readonly approvalStore: RegistrationApprovalStore;
  private readonly federationPeers: FederationPeerStore;
  private readonly federationNodes: FederationNodeRegistry;
  private readonly federationRouting: FederationRoutingStore;
  private readonly federationService: FederationService;
  private readonly callPush = new DisabledLoomCallPushGateway();
  private readonly federatedCalls: LoomFederatedCallGateway;
  private readonly calls: LoomCallRealtimeService;
  private readonly webSockets: WebSocketServer;
  private readonly accountRealtime: LoomAccountRealtimeService;
  private readonly server: Server;
  private readonly lanDiscovery: LoomLanDiscoveryResponder;
  private readonly localRouting: LocalRoutingWorker;
  private startedAt = Date.now();

  constructor(
    config: LoomNodeConfig,
    store?: SqliteStore | PostgresStore,
    attachments?: FilesystemAttachmentStore | S3AttachmentStore,
    approvalStore?: RegistrationApprovalStore,
    federationPeers?: FederationPeerStore,
    federationNodes?: FederationNodeRegistry,
    federationRouting?: FederationRoutingStore,
    deviceBundles?: DeviceBundleStore,
  ) {
    this.config = config;
    if (config.mode === 'production' && (!store || !attachments || !approvalStore || !federationPeers || !federationNodes || !federationRouting || !deviceBundles)) {
      throw new Error('Use LoomNodeServer.create() for production mode');
    }
    this.store = store ?? new SqliteStore(config.dataDirectory);
    this.identity = LoomNodeIdentity.loadOrCreate(config.dataDirectory);
    this.deviceBundles = deviceBundles ?? DeviceBundleStore.sqliteStore(config.dataDirectory);
    this.deviceRequests = new DeviceRequestVerifier(this.deviceBundles);
    this.groups = this.store instanceof SqliteStore ? new GroupStore(this.store.db) : new GroupStore(undefined, this.store.pool);
    this.groupCalls = new GroupCallService(config,this.groups);
    this.groupCallGateway = new GroupCallGateway(config,this.groupCalls);
    this.attachments = attachments ?? new FilesystemAttachmentStore(config.attachmentsDirectory, config.maxAttachmentBytes);
    this.approvalStore = approvalStore ?? RegistrationApprovalStore.sqliteStore(config.dataDirectory);
    this.federationPeers = federationPeers ?? FederationPeerStore.sqliteStore(config.dataDirectory);
    this.federationNodes = federationNodes ?? FederationNodeRegistry.sqliteStore(config.dataDirectory);
    this.federationRouting = federationRouting ?? FederationRoutingStore.sqliteStore(config.dataDirectory);
    this.federationService = new FederationService(config, this.identity, this.federationNodes, this.federationRouting);
    this.federatedCalls = new LoomFederatedCallGateway(config, this.identity, this.federationService);
    this.calls = new LoomCallRealtimeService(
      config,
      this.federationService,
      this.federatedCalls,
      this.callPush,
      async (accountId) => await this.store.listConversations(accountId) as Array<Record<string, unknown>>,
    );
    this.accountRealtime = new LoomAccountRealtimeService(async (accountId, cursor, limit) => this.store.sync(accountId, cursor, limit));
    this.localRouting = new LocalRoutingWorker(this.store, this.federationService, this.config.publicDomain, () => this.accountRealtime.notifyCommitted());
    this.webSockets = new WebSocketServer({ noServer: true, maxPayload: 768 * 1024, perMessageDeflate: false });
    this.server = createServer((req, res) => {
      if (req.method !== 'GET' && req.method !== 'HEAD') {
        res.once('finish', () => this.accountRealtime.notifyCommitted());
      }
      void this.admitHttp(req, res);
    });
    this.server.on('upgrade', (request, socket, head) => void this.handleUpgrade(request, socket, head));
    this.lanDiscovery = new LoomLanDiscoveryResponder(config, this.identity);
    this.server.maxConnections = 1024;
    this.server.requestTimeout = 30_000;
    this.server.headersTimeout = 15_000;
    this.server.keepAliveTimeout = 5_000;
  }

  static async create(config: LoomNodeConfig): Promise<LoomNodeServer> {
    if (config.mode === 'easy') return new LoomNodeServer(config);
    if (!config.databaseUrl || !config.objectStore) throw new Error('Production storage configuration is incomplete');
    const store = await PostgresStore.connect(config.databaseUrl);
    const attachments = await S3AttachmentStore.create(config.objectStore, config.maxAttachmentBytes);
    const approvalStore = await RegistrationApprovalStore.postgresStore(config.databaseUrl);
    const federationPeers = await FederationPeerStore.postgresStore(config.databaseUrl);
    const federationNodes = await FederationNodeRegistry.postgresStore(config.databaseUrl);
    const federationRouting = await FederationRoutingStore.postgresStore(config.databaseUrl);
    const deviceBundles = await DeviceBundleStore.postgresStore(config.databaseUrl);
    return new LoomNodeServer(config, store, attachments, approvalStore, federationPeers, federationNodes, federationRouting, deviceBundles);
  }

  async listen(): Promise<{ host: string; port: number }> {
    await this.groups.initialize();
    await new Promise<void>((resolve, reject) => {
      this.server.once('error', reject);
      this.server.listen(this.config.listenPort, this.config.listenHost, () => {
        this.server.off('error', reject);
        resolve();
      });
    });
    await this.lanDiscovery.start();
    this.federationService.start();
    this.localRouting.start();
    const address = this.server.address();
    if (!address || typeof address === 'string') throw new Error('Unexpected server address');
    return { host: address.address, port: address.port };
  }

  async close(): Promise<void> {
    this.accountRealtime.close();
    this.groupCalls.stop();
    this.groupCallGateway.close();
    await this.groupCalls.close();
    this.calls.close();
    try { this.webSockets.close(); } catch { /* best effort */ }
    await this.localRouting.stop();
    this.federationService.stop();
    await this.lanDiscovery.close();
    await new Promise<void>((resolve, reject) => this.server.close((error) => error ? reject(error) : resolve()));
    await this.deviceBundles.close();
    await this.federationRouting.close();
    await this.federationNodes.close();
    await this.federationPeers.close();
    await this.approvalStore.close();
    await this.store.close();
  }

  private async authenticated(request: IncomingMessage): Promise<SessionInfo | null> {
    const token = bearerToken(request);
    if (!token) return null;
    const session = await this.store.authenticate(token);
    if (!session) return null;
    this.limiter.consume("account", session.accountId, 600);
    this.limiter.consume("device", session.accountId + ":" + session.deviceId, 360);
    await this.deviceRequests.verify(request, session, token);
    return session;
  }

  private async handleUpgrade(request: IncomingMessage, socket: Duplex, head: Buffer): Promise<void> {
    const url = new URL(request.url ?? '/', 'http://localhost');
    const accountStream = url.searchParams.get('stream') === 'messages';
    if (url.pathname.startsWith('/conference/')) return this.groupCallGateway.upgrade(request,socket,head);
    if (url.pathname !== '/realtime/v1' || (!accountStream && !this.config.callsEnabled)) {
      socket.write('HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n');
      socket.destroy();
      return;
    }
    try {
      this.limiter.consume("upgrade:ip", request.socket.remoteAddress ?? "unknown", 30);
      const session = await this.authenticated(request);
      if (!session) {
        socket.write('HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n');
        socket.destroy();
        return;
      }
      this.webSockets.handleUpgrade(request, socket, head, (webSocket) => {
        if (accountStream) {
          this.accountRealtime.attach(session.accountId, webSocket, url.searchParams.get('cursor'));
        } else {
          this.calls.attach(session, webSocket);
        }
      });
    } catch (error) {
      if (error instanceof RateLimitError) {
        socket.end('HTTP/1.1 429 Too Many Requests\r\nRetry-After: 60\r\nConnection: close\r\n\r\n');
        return;
      }
      socket.write('HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n');
      socket.destroy();
    }
  }

  private adminAuthorized(request: IncomingMessage): boolean {
    const token = bearerToken(request);
    return Boolean(token && safeEqualUtf8(token, this.config.adminToken));
  }

  private async databaseDiagnostics(): Promise<Record<string, unknown>> {
    const started = Date.now();
    try {
      const stats = await this.store.stats();
      return { ready: true, backend: this.config.mode === 'production' ? 'postgresql' : 'sqlite', latencyMs: Date.now() - started, stats };
    } catch (error) {
      return { ready: false, backend: this.config.mode === 'production' ? 'postgresql' : 'sqlite', latencyMs: Date.now() - started, error: error instanceof Error ? error.message : String(error) };
    }
  }

  private async diagnostics(): Promise<Record<string, unknown>> {
    const database = await this.databaseDiagnostics();
    const attachments = await this.attachments.health();
    const identityInfo = this.identity.publicInfo();
    const identityReady = Boolean(identityInfo.nodeId && identityInfo.publicKey && identityInfo.fingerprint);
    const groups = await this.groups.diagnostics().catch(() => ({ infrastructureReady: false, messagingReady: false, protocol: 'Loom-MLS-v1', scope: 'home-node', reason: 'storage_unavailable' }));
    const ready = database.ready === true && attachments.ready === true && identityReady && groups.infrastructureReady;
    const pendingRegistrations = await this.approvalStore.pendingCount();
    const federation = await this.federationService.diagnostics();
    return {
      schemaVersion: 2,
      generatedAt: new Date().toISOString(),
      ready,
      overallStatus: ready ? 'healthy' : 'degraded',
      node: publicServerInfo(this.config, this.identity),
      runtime: { buildCommit: runningBuildCommit, mode: this.config.mode, uptimeSeconds: Math.floor((Date.now() - this.startedAt) / 1000), listenHost: this.config.listenHost, listenPort: this.config.listenPort },
      storage: { database, attachments },
      network: { publicDomain: this.config.publicDomain, publicBaseUrl: this.config.publicBaseUrl, tlsExpected: this.config.publicBaseUrl.toLowerCase().startsWith('https://'), lanDiscovery: this.config.lanDiscoveryEnabled === true },
      registration: {
        policy: this.config.registrationPolicy,
        acceptingRegistrations: this.config.registrationPolicy !== 'closed',
        automaticRegistration: this.config.registrationPolicy === 'open',
        approvalWorkflowReady: true,
        pendingRequests: pendingRegistrations,
        status: this.config.registrationPolicy === 'approval' ? 'approval_required' : this.config.registrationPolicy,
      },
      federation: {
        ...federation,
        discoveryReady: true,
        handshakeReady: this.config.federationMode !== 'disabled',
        ingressReady: this.config.federationMode !== 'disabled',
        routingReady: this.config.federationMode !== 'disabled',
        status: this.config.federationMode === 'disabled' ? 'disabled' : 'routing_ready',
      },
      messaging: { ...this.accountRealtime.diagnostics(), localRouting: this.localRouting.diagnostics() },
      groups,
      calls: {
        ...this.calls.diagnostics(),
        rtcReady: rtcReady(this.config),
        groupCallsEnabled: this.groupCalls.enabled,
        groupCallMaximum: this.groupCalls.enabled ? this.config.groupCalls!.maxParticipants : 0,
        stunConfigured: Boolean(this.config.rtcStunUrls?.length),
        turnConfigured: Boolean(this.config.rtcTurnUrls?.length && this.config.rtcTurnSharedSecret),
        turnTlsConfigured: Boolean(this.config.rtcTurnUrls?.some((url) => url.toLowerCase().startsWith('turns:'))),
        backgroundPushReady: this.callPush.available,
        mediaStoredByNode: false,
        mediaSecurity: 'WebRTC DTLS-SRTP; no additional application-layer media E2EE is claimed',
      },
      security: {
        nodeIdentityReady: identityReady,
        adminTokenConfigured: this.config.adminToken.length >= 32,
        nodeFingerprint: identityInfo.fingerprint,
        clientDeviceProofRequired: true,
        clientDeviceProofProtocol: 'Loom-Device-Request-v1',
        deviceLinking: 'password-authenticated bearer bootstrap plus short-lived encrypted QR package',
      },
      paths: { dataDirectory: this.config.dataDirectory, attachmentsDirectory: this.config.attachmentsDirectory },
    };
  }

  private async federationHandshakeAllowed(_request: IncomingMessage, input: ReturnType<typeof validateHandshake>): Promise<boolean> {
    if (this.config.federationMode === 'disabled') return false;
    const discovered = await this.federationService.discover(input.domain);
    if (discovered.nodeId !== input.nodeId || discovered.publicKey !== input.publicKey || discovered.endpoint !== input.endpoint) return false;
    if (this.config.federationMode === 'open') return discovered.trustState !== 'blocked';
    if (this.config.federationMode === 'trusted') return discovered.trustState === 'trusted';
    const endpointHost = new URL(discovered.endpoint).hostname.toLowerCase();
    const local = endpointHost === 'localhost' || endpointHost.endsWith('.local') || isPrivateOrLocalAddress(endpointHost);
    if (this.config.federationMode === 'local') return local;
    if (this.config.federationMode === 'hybrid') return discovered.trustState === 'trusted' || local;
    return false;
  }

  private async admitHttp(request: IncomingMessage, response: ServerResponse): Promise<void> {
    response.setHeader('referrer-policy', 'no-referrer');
    response.setHeader('permissions-policy', 'camera=(), microphone=(), geolocation=()');
    let release: (() => void) | undefined;
    try {
      const url = new URL(request.url ?? '/', 'http://localhost');
      const [scope, quota] = endpointClass(url.pathname);
      // Only the TCP peer is authoritative; forwarded headers are ignored.
      const ip = request.socket.remoteAddress ?? 'unknown';
      this.limiter.consume('ip', ip, 1200);
      this.limiter.consume(scope, ip, quota);
      const credential = bearerToken(request);
      if (credential) this.limiter.consume(scope + ':token', credential, quota);
      release = this.limiter.enter();
      await this.handle(request, response);
    } catch (error) {
      if (response.headersSent) { response.destroy(); return; }
      if (error instanceof RateLimitError) {
        response.setHeader('Retry-After', String(error.retryAfter));
        json(response, 429, { error: 'rate_limited' });
      } else {
        // Do not leak raw request/header values from adapter failures.
        json(response, 500, { error: 'internal_error' });
      }
    } finally { release?.(); }
  }

  private async handle(request: IncomingMessage, response: ServerResponse): Promise<void> {
    const method = request.method ?? 'GET';
    try {
      const url = new URL(request.url ?? '/', 'http://localhost');
      if(url.pathname.startsWith('/conference/'))return await this.groupCallGateway.validate(request,response);
      if(url.pathname==='/api/v1/group-calls/webhook'){
        if(method!=='POST')return json(response,405,{error:'method_not_allowed'});
        const parts:Buffer[]=[];let size=0;
        for await(const part of request){size+=part.length;if(size>65536)return json(response,413,{error:'body_too_large'});parts.push(Buffer.from(part));}
        await this.groupCalls.webhook(Buffer.concat(parts).toString('utf8'),request.headers.authorization??'');
        return json(response,200,{ok:true});
      }
      if (method === 'GET' && url.pathname === '/') return landingPage(response, this.config, await this.publicStatus(), this.shareUrl(), this.identity.publicInfo());
      const groupLink = /^\/g\/([A-Za-z0-9_-]{43})$/.exec(url.pathname);
      if (method === 'GET' && groupLink) {
        const node = new URL('/', this.config.publicBaseUrl).toString();
        const link = `loom://group/join?node=${encodeURIComponent(node)}&token=${groupLink[1]}`;
        response.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store',
          'content-security-policy': "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'" });
        return response.end(`<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Join a لوم group</title><style>body{font:18px system-ui;background:#10201c;color:#eee;max-width:520px;margin:12vh auto;padding:24px}a{display:inline-block;padding:16px;background:#66e8ba;color:#10201c;border-radius:16px;text-decoration:none}p{line-height:1.7}</style><h1>لوم group invitation</h1><p>Preview the group in لوم, then choose whether to join.</p><a href="${link.replaceAll('&','&amp;')}">Open in لوم · باز کردن گروه</a><p dir="rtl">اگر برنامه باز نشد، آدرس همین صفحه را در بخش «عضویت با لینک» برنامه وارد کنید.</p></html>`);
      }
      if (method === 'GET' && url.pathname === '/api/v1/server/status') {
        response.setHeader('cache-control', 'no-store');
        return json(response, 200, await this.publicStatus());
      }
      if (method === 'GET' && url.pathname === '/assets/node-status.js') {
        response.writeHead(200, { 'content-type': 'text/javascript; charset=utf-8', 'cache-control': 'public, max-age=300', 'x-content-type-options': 'nosniff' });
        return response.end(nodeStatusScript);
      }
      if (method === 'GET' && publicAssets.has(url.pathname)) {
        const asset = publicAssets.get(url.pathname)!;
        response.writeHead(200, { 'content-type': asset.type, 'content-length': String(asset.bytes.length),
          'cache-control': 'public, max-age=300', 'x-content-type-options': 'nosniff',
          'content-security-policy': "default-src 'none'; sandbox" });
        return response.end(asset.bytes);
      }
      if (method === 'GET' && url.pathname === '/node-qr.svg') {
        const svg = await (this.publicQr ??= QRCode.toString(this.shareUrl(), { type: 'svg', margin: 4, errorCorrectionLevel: 'M' }));
        response.writeHead(200, { 'content-type': 'image/svg+xml', 'cache-control': 'public, max-age=300', 'x-content-type-options': 'nosniff', 'content-security-policy': "default-src 'none'; sandbox" });
        return response.end(svg);
      }
      if (method === 'GET' && url.pathname === '/healthz') return text(response, 200, 'ok\n');
      if (method === 'GET' && url.pathname === '/readyz') {
        const d = await this.diagnostics();
        const storage = d.storage as Record<string, Record<string, unknown>>;
        return json(response, d.ready === true ? 200 : 503, {
          ready: d.ready === true,
          mode: this.config.mode,
          checks: {
            database: storage.database?.ready === true,
            attachments: storage.attachments?.ready === true,
            mlsGroups: (d.groups as Record<string, unknown>).infrastructureReady === true,
            nodeIdentity: (d.security as Record<string, unknown>).nodeIdentityReady === true,
          },
        });
      }
      if (method === 'GET' && url.pathname === '/.well-known/loom/server') return json(response, 200, wellKnownServer(this.config, this.identity));
      if (method === 'GET' && url.pathname === '/api/v1/server/info') return json(response, 200, publicServerInfo(this.config, this.identity));
      if (method === 'POST' && url.pathname === '/api/v1/server/challenge') {
        const body = await readJson(request, this.config.maxRequestBytes);
        const challenge = String(body.challenge ?? '');
        if (challenge.length < 16 || challenge.length > 512) return json(response, 400, { error: 'invalid_challenge' });
        const info = this.identity.publicInfo();
        return json(response, 200, { nodeId: info.nodeId, challenge, signature: this.identity.signUtf8(`loom-node-challenge-v1\n${challenge}`) });
      }
      if (method === 'POST' && url.pathname === '/api/v1/auth/register') {
        if (this.config.registrationPolicy === 'closed') return json(response, 403, { error: 'registration_closed' });
        const body = await readJson(request, this.config.maxRequestBytes);
        this.limiter.consume('register:account', String(body.username ?? '').trim().toLowerCase(), 5);
        requireRegistrationIdentity(body);
        if (this.config.registrationPolicy === 'approval') {
          const result = await this.approvalStore.request(body as never);
          return json(response, 202, { ...result, detail: 'Await operator approval, then sign in with the same username and password.' });
        }
        const result = await this.store.register(body as never, this.config.publicDomain);
        await this.store.ensureSelfConversation(result.accountId, result.address);
        return json(response, 201, result);
      }
      const registrationStatusMatch = /^\/api\/v1\/auth\/registrations\/([^/]+)$/.exec(url.pathname);
      if (method === 'GET' && registrationStatusMatch) {
        const result = await this.approvalStore.get(decodeURIComponent(registrationStatusMatch[1]));
        if (!result) return json(response, 404, { error: 'registration_request_not_found' });
        return json(response, 200, {
          requestId: result.requestId,
          username: result.username,
          status: result.status,
          createdAt: result.createdAt,
          reviewedAt: result.reviewedAt,
          reason: result.status === 'rejected' ? result.reason : undefined,
          address: result.status === 'approved' ? `@${result.username}:${this.config.publicDomain}` : undefined,
        });
      }
      if (method === 'POST' && url.pathname === '/api/v1/auth/login') {
        const body = await readJson(request, this.config.maxRequestBytes);
        this.limiter.consume('login:account', String(body.username ?? '').trim().toLowerCase(), 10);
        const result = await this.store.login(
          String(body.username ?? ''),
          String(body.password ?? ''),
          String(body.deviceName ?? 'Loom device'),
        );
        return json(response, 200, { ...result, address: `@${result.username}:${this.config.publicDomain}` });
      }
      if (method === 'POST' && url.pathname === '/api/v1/auth/refresh') {
        const body = await readJson(request, this.config.maxRequestBytes);
        const refreshToken = String(body.refreshToken ?? '');
        this.limiter.consume('refresh:token', refreshToken, 30);
        const refreshSession = await this.deviceBundles.sessionForRefreshToken(refreshToken);
        if (!refreshSession) return json(response, 401, { error: 'invalid_refresh_token' });
        await this.deviceRequests.verify(request, refreshSession, refreshToken);
        const result = await this.store.refresh(refreshToken);
        return json(response, 200, { ...result, address: `@${result.username}:${this.config.publicDomain}` });
      }

      if (method === 'POST' && url.pathname === '/api/v1/device-links/invitations') {
        const session = await this.authenticated(request);
        if (!session) return json(response, 401, { error: 'unauthorized' });
        const body = await readJson(request, this.config.maxRequestBytes);
        const invitation = this.deviceLinks.create(session, {
          linkId: String(body.linkId ?? ''),
          tokenHash: String(body.tokenHash ?? ''),
          payload: String(body.payload ?? ''),
        });
        return json(response, 201, {
          linkId: invitation.linkId,
          expiresAt: invitation.expiresAt,
          sourceDeviceId: invitation.sourceDeviceId,
        });
      }
      if (method === 'POST' && url.pathname === '/api/v1/device-links/redeem') {
        const access = bearerToken(request);
        if (!access) return json(response, 401, { error: 'unauthorized' });
        const session = await this.store.authenticate(access);
        if (!session) return json(response, 401, { error: 'unauthorized' });
        const body = await readJson(request, this.config.maxRequestBytes);
        const invitation = this.deviceLinks.redeem(
          session,
          String(body.linkId ?? ''),
          String(body.token ?? ''),
        );
        return json(response, 200, {
          linkId: invitation.linkId,
          payload: invitation.payload,
          identityId: invitation.identityId,
          sourceDeviceId: invitation.sourceDeviceId,
          expiresAt: invitation.expiresAt,
        });
      }
      if (method === 'POST' && url.pathname === '/api/v1/device-links/complete') {
        const session = await this.authenticated(request);
        if (!session) return json(response, 401, { error: 'unauthorized' });
        const body = await readJson(request, this.config.maxRequestBytes);
        this.deviceLinks.complete(session, String(body.linkId ?? ''));
        return json(response, 200, { completed: true });
      }

      const deviceBundleMatch = /^\/api\/v1\/devices\/([^/]+)\/key-bundle$/.exec(url.pathname);
      if (method === 'PUT' && deviceBundleMatch) {
        const session = await this.authenticated(request);
        if (!session) return json(response, 401, { error: 'unauthorized' });
        const deviceId = decodeURIComponent(deviceBundleMatch[1]);
        if (deviceId !== session.deviceId) return json(response, 403, { error: 'device_bundle_session_mismatch' });
        const body = await readJson(request, this.config.maxRequestBytes);
        const bundle = await this.deviceBundles.publish(session.accountId, session.identityId, session.deviceId, body);
        return json(response, 200, { ok: true, bundle });
      }
      const identityDevicesMatch = /^\/api\/v1\/identities\/([^/]+)\/devices$/.exec(url.pathname);
      if (method === 'GET' && identityDevicesMatch) {
        const session = await this.authenticated(request);
        if (!session) return json(response, 401, { error: 'unauthorized' });
        const identityId = decodeURIComponent(identityDevicesMatch[1]);
        return json(response, 200, { devices: await this.deviceBundles.listForIdentity(identityId) });
      }
      const revokeDeviceMatch = /^\/api\/v1\/devices\/([^/]+)\/revoke$/.exec(url.pathname);
      if (method === 'POST' && revokeDeviceMatch) {
        const session = await this.authenticated(request);
        if (!session) return json(response, 401, { error: 'unauthorized' });
        const deviceId = decodeURIComponent(revokeDeviceMatch[1]);
        const revoked = await this.deviceBundles.revokeDevice(session.accountId, deviceId);
        return revoked ? json(response, 200, { revoked: true, deviceId }) : json(response, 404, { error: 'device_not_found' });
      }

      if (method === 'GET' && url.pathname === '/api/v1/calls/rtc-config') {
        const session = await this.authenticated(request);
        if (!session) return json(response, 401, { error: 'unauthorized' });
        return json(response, 200, buildRtcConfiguration(this.config, session));
      }
      if (method === 'GET' && url.pathname === '/api/v1/calls/pending') {
        const session = await this.authenticated(request);
        if (!session) return json(response, 401, { error: 'unauthorized' });
        if (!this.config.callsEnabled) return json(response, 403, { error: 'calls_disabled' });
        return json(response, 200, { calls: await this.calls.pendingFor(session) });
      }

      if (url.pathname === '/api/v1/profile' && (method === 'GET' || method === 'PUT')) {
        const session = await this.authenticated(request);
        if (!session) return json(response, 401, { error: 'unauthorized' });
        response.setHeader('cache-control', 'no-store');
        const profile = method === 'GET'
          ? await this.store.readProfile(session.accountId, this.config.publicDomain)
          : await this.store.updateProfile(session.accountId, this.config.publicDomain,
              validateProfileUpdate(await readJson(request, Math.min(this.config.maxRequestBytes, 512 * 1024))));
        return json(response, 200, profile);
      }
      if (method === 'GET' && url.pathname === '/api/v1/conversations') {
        const session = await this.authenticated(request);
        if (!session) return json(response, 401, { error: 'unauthorized' });
        return json(response, 200, { conversations: await this.store.listConversations(session.accountId) });
      }
      if (method === 'POST' && url.pathname === '/api/v1/conversations') {
        const session = await this.authenticated(request);
        if (!session) return json(response, 401, { error: 'unauthorized' });
        const body = await readJson(request, this.config.maxRequestBytes);
        const result = await this.federationService.createRemoteConversation(session.accountId, String(body.address ?? ''));
        return json(response, 201, result);
      }
      if (method === 'POST' && url.pathname === '/api/v1/users/resolve') {
        const session = await this.authenticated(request);
        if (!session) return json(response, 401, { error: 'unauthorized' });
        const body = await readJson(request, this.config.maxRequestBytes);
        const address = parseLoomAddress(String(body.address ?? ''), this.config.publicDomain);
        const profile = await this.federationService.resolveUser(address.canonical, true);
        if (address.isLocal) {
          return json(response, 200, { ...profile, devices: await this.deviceBundles.listForIdentity(profile.identity.identityId) });
        }
        return json(response, 200, profile);
      }
      if (url.pathname === '/api/v1/groups' || url.pathname.startsWith('/api/v1/groups/')) {
        const session = await this.authenticated(request);
        if (!session) return json(response, 401, { error: 'unauthorized' });
        const parts = url.pathname.split('/').slice(4);
        if(parts.length>=2&&parts[1]==='call'){
          if(parts.length===2&&method==='GET')return json(response,200,await this.groupCalls.view(session,parts[0]));
          const action=parts[2];
          if(parts.length!==3||method!=='POST'||!['start','join','heartbeat','leave','control'].includes(action))return json(response,404,{error:'not_found'});
          this.limiter.consume('group-call:'+action,session.accountId,action==='heartbeat'?120:action==='join'?6:action==='start'?3:30);
          const body=await readJson(request,4096);
          const result=action==='start'?await this.groupCalls.start(session,parts[0],body):action==='join'?await this.groupCalls.join(session,parts[0],body):action==='heartbeat'?await this.groupCalls.heartbeat(session,parts[0],body):action==='leave'?await this.groupCalls.leave(session,parts[0],body):await this.groupCalls.control(session,parts[0],body);
          return json(response,200,result);
        }
        if (method === 'GET' && parts.length === 0) return json(response, 200, await this.groups.list(session));
        if (parts[0] === 'invites' && parts.length === 2 && method === 'GET') return json(response, 200, await this.groups.previewInvite(session, parts[1]));
        if (parts[0] === 'invites' && parts.length === 3 && parts[2] === 'join' && method === 'POST') return json(response, 200, await this.groups.requestJoin(session, parts[1]));
        if (parts[0] === 'devices' && parts.length === 3 && parts[2] === 'profile' && method === 'GET') return json(response, 200, await this.groups.memberProfile(session, parts[1]));
        if (parts.length === 2 && parts[1] === 'invites' && method === 'POST') return json(response, 201, await this.groups.createInvite(session, parts[0], await readJson(request, 2048)));
        if (parts.length === 2 && parts[1] === 'invites' && method === 'DELETE') return json(response, 200, await this.groups.revokeInvites(session, parts[0]));
        if (parts.length === 2 && parts[1] === 'join-requests' && method === 'GET') return json(response, 200, await this.groups.joinRequests(session, parts[0]));
        if (parts.length === 3 && parts[1] === 'join-requests' && method === 'POST') {
          const body = await readJson(request, 2048);
          if (typeof body.approve !== 'boolean') return json(response, 400, { error: 'invalid_group_join_decision' });
          return json(response, 200, await this.groups.decideJoin(session, parts[0], parts[2], body.approve));
        }
        if (parts[0] === 'devices' && parts.length === 3 && parts[2] === 'credential') {
          if (method === 'GET') return json(response, 200, await this.groups.credential(session, parts[1]));
          if (method === 'POST') {
            if (parts[1] !== session.deviceId) return json(response,403,{error:'device_not_authorized'});
            const key=await this.deviceBundles.signingKeyForSession(session.accountId,session.identityId,session.deviceId);
            if (!key) return json(response,403,{error:'device_key_bundle_required'});
            return json(response,200,await this.groups.publishCredential(session,await readJson(request,Math.min(this.config.maxRequestBytes,8192)),key));
          }
        }
        if (method === 'GET' && parts[0] === 'key-packages' && parts.length === 1) return json(response, 200, await this.groups.packageStock(session));
        if (method === 'POST' && parts[0] === 'key-packages' && parts.length === 1) {
          const key = await this.deviceBundles.signingKeyForSession(session.accountId, session.identityId, session.deviceId);
          if (!key) return json(response, 403, { error: 'device_key_bundle_required' });
          return json(response, 201, await this.groups.publish(session, await readJson(request, Math.min(this.config.maxRequestBytes, 100000)), key));
        }
        if (method === 'POST' && parts[0] === 'key-packages' && parts.length === 3 && parts[2] === 'claim') return json(response, 200, await this.groups.claim(session, parts[1]));
        if (parts.length === 1 && method === 'GET') return json(response, 200, await this.groups.get(session, parts[0]));
        if (parts.length === 1 && method === 'POST') return json(response, 201, await this.groups.create(session, parts[0], await readJson(request, this.config.maxRequestBytes)));
        if (parts.length === 2 && parts[1] === 'commits' && method === 'POST') {
          const body = await readJson(request, this.config.maxRequestBytes);
          const result=await this.groups.commit(session, parts[0], Number(body.expectedRevision), body);
          await this.groupCalls.membershipChanged(parts[0]);
          return json(response,200,result);
        }
        if (parts.length === 2 && parts[1] === 'messages' && method === 'POST') return json(response, 201, await this.groups.send(session, parts[0], await readJson(request, this.config.maxRequestBytes)));
        if (parts.length === 2 && parts[1] === 'inbox' && method === 'GET') return json(response, 200, await this.groups.inbox(session, parts[0], Number(url.searchParams.get('after') ?? '0')));
        return json(response, 404, { error: 'not_found' });
      }
      if (method === 'POST' && url.pathname === '/api/v1/messages') {
        const session = await this.authenticated(request);
        if (!session) return json(response, 401, { error: 'unauthorized' });
        const body = await readJson(request, this.config.maxRequestBytes);
        const senderAddress = `@${session.username}:${this.config.publicDomain}`;
        const message = {
          conversationId: String(body.conversationId ?? ''),
          clientId: String(body.clientId ?? ''),
          senderAddress,
          type: String(body.type ?? ''),
          ciphertext: String(body.ciphertext ?? ''),
          protocolVersion: String(body.protocolVersion ?? ''),
          replyToMessageId: body.replyToMessageId == null ? null : String(body.replyToMessageId),
          metadata: body.metadata ?? {},
        };
        const receipt = await this.store.createMessage(session.accountId, message);
        this.localRouting.kick();
        return json(response, 201, { ...receipt, routing: 'durably_queued' });
      }
      const presenceMatch = /^\/api\/v1\/conversations\/([^/]+)\/presence$/.exec(url.pathname);
      if (method === 'GET' && presenceMatch) {
        const session = await this.authenticated(request);
        if (!session) return json(response, 401, { error: 'unauthorized' });
        return json(response, 200, await this.store.conversationPresence(session.accountId, decodeURIComponent(presenceMatch[1]), this.config.publicDomain));
      }
      if (method === 'POST' && url.pathname === '/api/v1/messages/received') {
        const session = await this.authenticated(request);
        if (!session) return json(response, 401, { error: 'unauthorized' });
        const body = await readJson(request, this.config.maxRequestBytes);
        const ids = body.clientIds;
        if (!Array.isArray(ids) || ids.length > 50 || ids.some(id => typeof id !== 'string' || id.length < 1 || id.length > 256)) return json(response, 400, { error: 'invalid_receipts' });
        await this.store.acknowledgeReceived(session.accountId, `@${session.username}:${this.config.publicDomain}`, ids);
        await this.federationService.acknowledgeReceived(session.accountId, `@${session.username}:${this.config.publicDomain}`, ids);
        return json(response, 200, { ok: true });
      }
      if (method === 'GET' && url.pathname === '/api/v1/sync') {
        const session = await this.authenticated(request);
        if (!session) return json(response, 401, { error: 'unauthorized' });
        await this.store.touchPresence(session.accountId);
        return json(response, 200, await this.store.sync(session.accountId, url.searchParams.get('cursor'), Number(url.searchParams.get('limit') ?? 200)));
      }
      const readMatch = /^\/api\/v1\/conversations\/([^/]+)\/read$/.exec(url.pathname);
      if (method === 'POST' && readMatch) {
        const session = await this.authenticated(request);
        if (!session) return json(response, 401, { error: 'unauthorized' });
        const body = await readJson(request, this.config.maxRequestBytes);
        await this.store.markRead(session.accountId, decodeURIComponent(readMatch[1]), Number(body.throughOrder));
        return json(response, 200, { ok: true });
      }
      if (await serveEncryptedAttachment(request, response, url.pathname, this.attachments)) return;
      if (method === 'POST' && url.pathname === '/api/v1/attachments') {
        const session = await this.authenticated(request);
        if (!session) return json(response, 401, { error: 'unauthorized' });
        const stored = await this.attachments.store(request);
        const declaredHash = String(request.headers['x-loom-content-sha256'] ?? '').toLowerCase();
        if (!declaredHash || stored.sha256.toLowerCase() !== declaredHash) throw new Error('device_request_body_hash_mismatch');
        const encryptedContentType = String(request.headers['x-loom-encrypted-content-type'] ?? 'application/octet-stream').slice(0, 128);
        return json(response, 201, { attachmentId: stored.id, sizeBytes: stored.bytes, contentType: encryptedContentType, sha256: stored.sha256 });
      }

      if (method === 'GET' && url.pathname === '/federation/v1/info') return json(response, 200, { ...publicServerInfo(this.config, this.identity), federationProtocol: 'loom-federation-v1' });
      if (method === 'POST' && url.pathname === '/federation/v1/handshake') {
        if (this.config.federationMode === 'disabled') return json(response, 403, { error: 'federation_disabled' });
        const body = await readJson(request, this.config.maxRequestBytes);
        const verified = validateHandshake(body as unknown as FederationHandshake);
        if (!await this.federationHandshakeAllowed(request, verified)) return json(response, 403, { error: 'federation_peer_not_allowed' });
        const remembered = await this.federationPeers.rememberNonce(verified.nodeId, verified.nonce, new Date(Date.now() + 10 * 60_000));
        if (!remembered) return json(response, 409, { error: 'federation_replay_detected' });
        return json(response, 200, createHandshakeResponse(this.identity, verified.nodeId, this.config.publicDomain, this.config.publicBaseUrl, verified.nonce));
      }
      if (method === 'POST' && url.pathname === '/federation/v1/users/resolve') {
        if (this.config.federationMode === 'disabled') return json(response, 403, { error: 'federation_disabled' });
        const body = await readJson(request, this.config.maxRequestBytes);
        const verified = validateHandshake(body.handshake as FederationHandshake);
        if (!await this.federationHandshakeAllowed(request, verified)) return json(response, 403, { error: 'federation_peer_not_allowed' });
        const remembered = await this.federationPeers.rememberNonce(verified.nodeId, verified.nonce, new Date(Date.now() + 10 * 60_000));
        if (!remembered) return json(response, 409, { error: 'federation_replay_detected' });
        const address = parseLoomAddress(String(body.address ?? ''), this.config.publicDomain);
        if (!address.isLocal) return json(response, 404, { error: 'user_not_found' });
        const profile = await this.federationRouting.resolveLocalUser(address.username, address.domain);
        if (!profile) return json(response, 404, { error: 'user_not_found' });
        profile.homeNode.nodeId = this.identity.publicInfo().nodeId;
        const devices = await this.deviceBundles.listForIdentity(profile.identity.identityId);
        return json(response, 200, signFederationUserProfile(this.identity, { ...profile, devices }));
      }
      if (method === 'POST' && url.pathname === '/federation/v1/events') {
        if (this.config.federationMode === 'disabled') return json(response, 403, { error: 'federation_disabled' });
        const envelope = await readJson(request, this.config.maxRequestBytes) as unknown as FederationEnvelope;
        const result = await this.federationService.acceptInbound(envelope, request);
        return json(response, result.duplicate ? 200 : 202, { accepted: true, ...result });
      }
      if (method === 'POST' && url.pathname === '/federation/v1/calls/signal') {
        if (!this.config.callsEnabled) return json(response, 403, { error: 'calls_disabled' });
        if (this.config.federationMode === 'disabled') return json(response, 403, { error: 'federation_disabled' });
        const envelope = await readJson(request, this.config.maxRequestBytes) as unknown as FederatedCallSignal;
        await this.calls.acceptFederated(envelope);
        return json(response, 202, { accepted: true });
      }

      if (url.pathname === '/admin/v1/groups' || url.pathname.startsWith('/admin/v1/groups/')) {
        if (!this.adminAuthorized(request)) return json(response, 401, { error: 'unauthorized' });
        if (url.pathname === '/admin/v1/groups') {
          if (method !== 'GET') return json(response, 405, { error: 'method_not_allowed' });
          return json(response, 200, await this.groups.adminList(Number(url.searchParams.get('limit') ?? 50), url.searchParams.get('after') ?? ''));
        }
        if (url.pathname === '/admin/v1/groups/key-packages/cleanup') {
          if (method !== 'POST') return json(response, 405, { error: 'method_not_allowed' });
          return json(response, 200, await this.groups.adminCleanupPackages());
        }
        const match = /^\/admin\/v1\/groups\/([^/]+)(\/policy)?$/.exec(url.pathname);
        if (!match) return json(response, 404, { error: 'not_found' });
        const groupId = decodeURIComponent(match[1]);
        if (!match[2]) {
          if (method !== 'GET') return json(response, 405, { error: 'method_not_allowed' });
          return json(response, 200, await this.groups.adminGet(groupId));
        }
        if (method !== 'POST') return json(response, 405, { error: 'method_not_allowed' });
        return json(response, 200, await this.groups.adminSetPolicy(groupId, await readJson(request, 2048)));
      }

      if (url.pathname === '/admin/v1/diagnostics') {
        if (!this.adminAuthorized(request)) return json(response, 401, { error: 'unauthorized' });
        if (method !== 'GET') return json(response, 405, { error: 'method_not_allowed' });
        return json(response, 200, await this.diagnostics());
      }
      if (url.pathname === '/admin/v1/registrations') {
        if (!this.adminAuthorized(request)) return json(response, 401, { error: 'unauthorized' });
        if (method !== 'GET') return json(response, 405, { error: 'method_not_allowed' });
        const status = url.searchParams.get('status') ?? 'pending';
        if (!['pending', 'approved', 'rejected'].includes(status)) return json(response, 400, { error: 'invalid_registration_status' });
        return json(response, 200, { requests: await this.approvalStore.list(status as 'pending' | 'approved' | 'rejected', Number(url.searchParams.get('limit') ?? 100)) });
      }
      const registrationAdminMatch = /^\/admin\/v1\/registrations\/([^/]+)\/(approve|reject)$/.exec(url.pathname);
      if (registrationAdminMatch) {
        if (!this.adminAuthorized(request)) return json(response, 401, { error: 'unauthorized' });
        if (method !== 'POST') return json(response, 405, { error: 'method_not_allowed' });
        const requestId = decodeURIComponent(registrationAdminMatch[1]);
        if (registrationAdminMatch[2] === 'approve') return json(response, 200, await this.approvalStore.approve(requestId, this.config.publicDomain));
        const body = await readJson(request, this.config.maxRequestBytes);
        return json(response, 200, await this.approvalStore.reject(requestId, body.reason == null ? undefined : String(body.reason)));
      }
      if (url.pathname === '/admin/v1/federation/status') {
        if (!this.adminAuthorized(request)) return json(response, 401, { error: 'unauthorized' });
        if (method !== 'GET') return json(response, 405, { error: 'method_not_allowed' });
        return json(response, 200, await this.federationService.diagnostics());
      }
      if (url.pathname === '/admin/v1/federation/nodes' || url.pathname === '/admin/v1/federation/peers') {
        if (!this.adminAuthorized(request)) return json(response, 401, { error: 'unauthorized' });
        if (method === 'GET') {
          const nodes = await this.federationNodes.list();
          return json(response, 200, { nodes, peers: nodes });
        }
        if (method === 'POST') {
          const body = await readJson(request, this.config.maxRequestBytes);
          const domain = String(body.domain ?? body.endpoint ?? '').replace(/^https?:\/\//, '').replace(/\/$/, '');
          return json(response, 201, await this.federationService.discover(domain, true));
        }
        return json(response, 405, { error: 'method_not_allowed' });
      }
      if (url.pathname === '/admin/v1/federation/queue') {
        if (!this.adminAuthorized(request)) return json(response, 401, { error: 'unauthorized' });
        if (method === 'GET') return json(response, 200, { deliveries: await this.federationRouting.listQueue(Number(url.searchParams.get('limit') ?? 100)), summary: (await this.federationRouting.diagnostics()).queue });
        return json(response, 405, { error: 'method_not_allowed' });
      }
      if (url.pathname === '/admin/v1/federation/queue/retry-failed') {
        if (!this.adminAuthorized(request)) return json(response, 401, { error: 'unauthorized' });
        if (method !== 'POST') return json(response, 405, { error: 'method_not_allowed' });
        return json(response, 200, { retried: await this.federationRouting.retryFailed() });
      }
      if (url.pathname === '/admin/v1/federation/queue/dead-letter') {
        if (!this.adminAuthorized(request)) return json(response, 401, { error: 'unauthorized' });
        if (method !== 'DELETE') return json(response, 405, { error: 'method_not_allowed' });
        return json(response, 200, { purged: await this.federationRouting.purgeFailed() });
      }
      const retryMatch = /^\/admin\/v1\/federation\/queue\/([^/]+)\/retry$/.exec(url.pathname);
      if (retryMatch) {
        if (!this.adminAuthorized(request)) return json(response, 401, { error: 'unauthorized' });
        if (method !== 'POST') return json(response, 405, { error: 'method_not_allowed' });
        return json(response, 200, { retried: await this.federationRouting.retryFailed(decodeURIComponent(retryMatch[1])) });
      }
      const nodeAction = /^\/admin\/v1\/federation\/(?:nodes|peers)\/([^/]+)\/(trust|block|verify|probe)$/.exec(url.pathname);
      if (nodeAction) {
        if (!this.adminAuthorized(request)) return json(response, 401, { error: 'unauthorized' });
        if (method !== 'POST') return json(response, 405, { error: 'method_not_allowed' });
        const nodeId = decodeURIComponent(nodeAction[1]);
        const existing = await this.federationNodes.get(nodeId);
        if (!existing) return json(response, 404, { error: 'federation_peer_not_found' });
        if (nodeAction[2] === 'trust') return json(response, 200, await this.federationNodes.setTrust(nodeId, 'trusted'));
        if (nodeAction[2] === 'block') return json(response, 200, await this.federationNodes.setTrust(nodeId, 'blocked'));
        const verified = await this.federationService.discover(existing.domain, true);
        return json(response, 200, { ok: true, node: verified });
      }
      const nodeDelete = /^\/admin\/v1\/federation\/(?:nodes|peers)\/([^/]+)$/.exec(url.pathname);
      if (nodeDelete) {
        if (!this.adminAuthorized(request)) return json(response, 401, { error: 'unauthorized' });
        if (method !== 'DELETE') return json(response, 405, { error: 'method_not_allowed' });
        const nodeId = decodeURIComponent(nodeDelete[1]);
        const removed = await this.federationNodes.remove(nodeId);
        return removed ? json(response, 200, { removed: true, nodeId }) : json(response, 404, { error: 'federation_peer_not_found' });
      }
      if (url.pathname === '/admin/v1/users') {
        if (!this.adminAuthorized(request)) return json(response, 401, { error: 'unauthorized' });
        if (method !== 'GET') return json(response, 405, { error: 'method_not_allowed' });
        return json(response, 200, { users: await this.federationRouting.listUsers(Number(url.searchParams.get('limit') ?? 200)) });
      }
      if (url.pathname === '/admin/v1/status') {
        if (!this.adminAuthorized(request)) return json(response, 401, { error: 'unauthorized' });
        if (method !== 'GET') return json(response, 405, { error: 'method_not_allowed' });
        const d = await this.diagnostics();
        const database = (d.storage as Record<string, Record<string, unknown>>).database;
        return json(response, 200, {
          node: publicServerInfo(this.config, this.identity),
          mode: this.config.mode,
          uptimeSeconds: Math.floor((Date.now() - this.startedAt) / 1000),
          stats: database.stats ?? await this.store.stats(),
          federation: d.federation,
          calls: d.calls,
          groups: d.groups,
          paths: { dataDirectory: this.config.dataDirectory, attachmentsDirectory: this.config.attachmentsDirectory },
          readiness: { ready: d.ready, overallStatus: d.overallStatus },
        });
      }
      return json(response, 404, { error: 'not_found' });
    } catch (error: unknown) {
      if (error instanceof GroupError) return json(response, error.status, { error: error.message });
      if (error instanceof RateLimitError) {
        response.setHeader('Retry-After', String(error.retryAfter));
        return json(response, 429, { error: 'rate_limited' });
      }
      const code = error instanceof Error ? error.message : 'internal_error';
      const bad = [
        'invalid_profile_update', 'invalid_profile_avatar', 'invalid_username', 'invalid_display_name', 'invalid_password', 'invalid_identity', 'unsupported_identity_protocol',
        'invalid_ciphertext', 'invalid_protocol_version', 'invalid_read_order', 'invalid_cursor', 'content_type', 'body_too_large', 'json_object_required', 'invalid_registration_status',
        'invalid_device_bundle', 'unsupported_device_bundle_version', 'invalid_device_bundle_fingerprint', 'invalid_device_bundle_signature', 'invalid_device_identity_signature', 'device_bundle_session_mismatch', 'device_bundle_identity_mismatch',
        'invalid_device_request_proof', 'invalid_device_request_timestamp', 'invalid_device_request_nonce', 'invalid_device_request_body_hash', 'device_request_body_hash_mismatch', 'invalid_device_request_target', 'invalid_device_request_credential',
        'invalid_device_link_id', 'invalid_device_link_token', 'invalid_device_link_payload', 'device_link_same_device',
        'invalid_federation_public_key', 'federation_requires_https', 'invalid_federation_endpoint', 'unsupported_federation_protocol', 'federation_node_id_mismatch', 'invalid_federation_discovery_signature', 'federation_endpoint_mismatch', 'invalid_federation_nonce', 'stale_federation_handshake', 'federation_domain_endpoint_mismatch', 'invalid_federation_handshake_signature',
        'invalid_loom_address', 'invalid_loom_username', 'invalid_loom_domain', 'invalid_federation_event_id', 'stale_federation_event', 'invalid_federation_recipients', 'federation_recipient_domain_mismatch', 'federation_sender_origin_mismatch', 'invalid_federation_payload', 'invalid_federation_user_devices',
        'invalid_call_federation_event_id', 'invalid_call_signal_kind', 'invalid_call_signal', 'invalid_call_identity', 'invalid_call_display_name', 'invalid_call_sequence', 'stale_call_signal', 'invalid_call_media_kind', 'call_sdp_too_large', 'call_candidate_too_large', 'invalid_call_sdp_type', 'invalid_call_sdp_mid', 'invalid_call_mline', 'invalid_call_reason',
      ];
      const notFound = ['conversation_not_found', 'registration_request_not_found', 'federation_peer_not_found', 'user_not_found', 'federation_recipient_not_found', 'device_not_found', 'call_conversation_not_found', 'device_link_not_found', 'device_link_expired'];
      const unauthorized = ['invalid_credentials', 'invalid_refresh_token', 'device_request_proof_required', 'device_key_bundle_required', 'invalid_device_request_signature', 'stale_device_request', 'device_link_token_mismatch'];
      const forbidden = ['federation_disabled', 'federation_peer_not_trusted', 'federation_peer_not_allowed', 'federation_node_blocked', 'group_encryption_unavailable', 'voice_calls_disabled', 'video_calls_disabled', 'device_not_authorized', 'device_request_session_mismatch', 'calls_disabled', 'call_target_identity_mismatch', 'call_sender_identity_mismatch', 'invalid_call_federation_signature', 'device_link_account_mismatch', 'device_link_target_mismatch'];
      const conflict = ['username_taken', 'identity_already_registered', 'registration_request_exists', 'registration_request_not_pending', 'federation_replay_detected', 'federation_peer_identity_changed', 'federation_node_key_changed', 'device_key_change_requires_rotation', 'device_request_replay_detected', 'device_link_exists', 'device_link_limit'];
      const unavailable = ['turn_required', 'turn_credentials_unavailable'];
      const status = bad.includes(code) ? 400 : notFound.includes(code) ? 404 : unauthorized.includes(code) ? 401 : forbidden.includes(code) ? 403 : conflict.includes(code) ? 409 : unavailable.includes(code) ? 503 : 500;
      if (status === 500) console.error('[loom-node] request failed', error);
      return json(response, status, { error: status === 500 ? 'internal_error' : code });
    }
  }
}



