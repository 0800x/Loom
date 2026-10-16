import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { randomBytes } from 'node:crypto';

export type NodeMode = 'easy' | 'production';
export type RegistrationPolicy = 'open' | 'approval' | 'closed';
export type FederationMode = 'disabled' | 'trusted' | 'open' | 'local' | 'hybrid';

export interface LoomNodeConfig {
  schemaVersion: 1;
  mode: NodeMode;
  listenHost: string;
  listenPort: number;
  publicDomain: string;
  publicBaseUrl: string;
  dataDirectory: string;
  attachmentsDirectory: string;
  registrationPolicy: RegistrationPolicy;
  federationMode: FederationMode;
  networkJurisdiction: string;
  operatorName: string;
  adminToken: string;
  maxAttachmentBytes: number;
  maxRequestBytes: number;
  publicResourceMetrics?: boolean;
  lanDiscoveryEnabled?: boolean;
  lanAdvertiseEndpoint?: string;
  databaseUrl?: string;
  objectStore?: {
    endpoint?: string;
    region: string;
    bucket: string;
    accessKeyId: string;
    secretAccessKey: string;
    forcePathStyle?: boolean;
  };

  // Calls are opt-in at the Node. Existing installations therefore do not
  // accidentally advertise a production calling feature without TURN.
  groupCalls?: {enabled:boolean;apiUrl:string;apiKey:string;apiSecret:string;maxParticipants:number};
  callsEnabled?: boolean;
  voiceCallsEnabled?: boolean;
  videoCallsEnabled?: boolean;
  rtcStunUrls?: string[];
  rtcTurnUrls?: string[];
  rtcTurnSharedSecret?: string;
  rtcCredentialTtlSeconds?: number;
}

const DEFAULT_PORT = 7483;
const DEFAULT_RTC_CREDENTIAL_TTL_SECONDS = 600;

function isDevelopmentLoopback(hostname: string): boolean {
  return ['localhost', '127.0.0.1', '::1', '[::1]'].includes(hostname.toLowerCase());
}

export function requireProductionSecret(name: string, value: string | undefined, minLength = 1): void {
  const normalized = value?.trim().toLowerCase() ?? '';
  if (!normalized || value!.length < minLength || /[\r\n\x00]/.test(value!) ||
      /^(replace[-_ ]|change[-_ ]?me|your[-_ ]|example[-_ ])/.test(normalized) ||
      ['minioadmin', 'password', 'postgres', 'loom', 'admin', 'secret', 'changeme', 'default'].includes(normalized)) {
    throw new Error('Invalid production credential: ' + name);
  }
}

export function configPathFromEnv(): string {
  return resolve(process.env.LOOM_CONFIG ?? './data/loom-node.json');
}

function cleanDomain(value: string): string {
  const domain = value.trim().toLowerCase();
  if (!/^[a-z0-9.-]+(?::\d+)?$/.test(domain) || domain.includes('..')) {
    throw new Error(`Invalid LOOM_PUBLIC_DOMAIN: ${value}`);
  }
  return domain;
}

function boolLikeMode(value: string | undefined): NodeMode {
  return value?.toLowerCase() === 'production' ? 'production' : 'easy';
}

function csv(value: string | undefined): string[] | undefined {
  if (!value?.trim()) return undefined;
  const values = value.split(',').map((item) => item.trim()).filter(Boolean);
  return values.length > 0 ? values : undefined;
}

function validIceUrl(value: string, allowed: readonly string[]): boolean {
  if (!value || value.length > 2048 || /[\r\n]/.test(value)) return false;
  const lower = value.toLowerCase();
  return allowed.some((scheme) => lower.startsWith(`${scheme}:`));
}

export function createDefaultConfig(): LoomNodeConfig {
  const mode = boolLikeMode(process.env.LOOM_MODE);
  const dataDirectory = resolve(process.env.LOOM_DATA_DIR ?? './data');
  const listenPort = Number(process.env.LOOM_PORT ?? DEFAULT_PORT);
  if (!Number.isInteger(listenPort) || listenPort < 1 || listenPort > 65535) {
    throw new Error('LOOM_PORT must be an integer between 1 and 65535');
  }
  const publicDomain = cleanDomain(process.env.LOOM_PUBLIC_DOMAIN ?? `localhost:${listenPort}`);
  const domainHost = new URL(`http://${publicDomain}`).hostname;
  const defaultScheme = isDevelopmentLoopback(domainHost) ? 'http' : 'https';
  const publicBaseUrl = process.env.LOOM_PUBLIC_BASE_URL ?? `${defaultScheme}://${publicDomain}`;
  return {
    schemaVersion: 1,
    mode,
    listenHost: process.env.LOOM_HOST ?? '127.0.0.1',
    listenPort,
    publicDomain,
    publicBaseUrl,
    dataDirectory,
    attachmentsDirectory: resolve(process.env.LOOM_ATTACHMENTS_DIR ?? `${dataDirectory}/attachments`),
    registrationPolicy: (process.env.LOOM_REGISTRATION_POLICY as RegistrationPolicy | undefined) ?? 'approval',
    federationMode: (process.env.LOOM_FEDERATION_MODE as FederationMode | undefined) ?? 'disabled',
    networkJurisdiction: process.env.LOOM_NETWORK_JURISDICTION ?? 'Unspecified',
    operatorName: process.env.LOOM_OPERATOR_NAME ?? 'Private operator',
    adminToken: process.env.LOOM_ADMIN_TOKEN ?? randomBytes(32).toString('base64url'),
    publicResourceMetrics: process.env.LOOM_PUBLIC_RESOURCE_METRICS === 'true',
    maxAttachmentBytes: Number(process.env.LOOM_MAX_ATTACHMENT_BYTES ?? 100 * 1024 * 1024),
    maxRequestBytes: Number(process.env.LOOM_MAX_REQUEST_BYTES ?? 1024 * 1024),
    lanDiscoveryEnabled: process.env.LOOM_LAN_DISCOVERY === 'true',
    lanAdvertiseEndpoint: process.env.LOOM_LAN_ENDPOINT,
    databaseUrl: process.env.LOOM_DATABASE_URL,
    objectStore: process.env.LOOM_S3_BUCKET ? {
      endpoint: process.env.LOOM_S3_ENDPOINT,
      region: process.env.LOOM_S3_REGION ?? 'us-east-1',
      bucket: process.env.LOOM_S3_BUCKET,
      accessKeyId: process.env.LOOM_S3_ACCESS_KEY_ID ?? '',
      secretAccessKey: process.env.LOOM_S3_SECRET_ACCESS_KEY ?? '',
      forcePathStyle: process.env.LOOM_S3_FORCE_PATH_STYLE === 'true',
    } : undefined,
    groupCalls: groupCallEnvironment(),
    callsEnabled: process.env.LOOM_CALLS_ENABLED === 'true',
    voiceCallsEnabled: process.env.LOOM_VOICE_CALLS_ENABLED !== 'false',
    videoCallsEnabled: process.env.LOOM_VIDEO_CALLS_ENABLED !== 'false',
    rtcStunUrls: csv(process.env.LOOM_STUN_URLS),
    rtcTurnUrls: csv(process.env.LOOM_TURN_URLS),
    rtcTurnSharedSecret: process.env.LOOM_TURN_SHARED_SECRET,
    rtcCredentialTtlSeconds: Number(process.env.LOOM_TURN_CREDENTIAL_TTL_SECONDS ?? DEFAULT_RTC_CREDENTIAL_TTL_SECONDS),
  };
}

export function validateConfig(config: LoomNodeConfig): void {
  if (config.schemaVersion !== 1) throw new Error('Unsupported Node configuration schema');
  if (!['easy', 'production'].includes(config.mode)) throw new Error('Invalid Node mode');
  if (!['open', 'approval', 'closed'].includes(config.registrationPolicy)) throw new Error('Invalid registration policy');
  if (!['disabled', 'trusted', 'open', 'local', 'hybrid'].includes(config.federationMode)) throw new Error('Invalid federation mode');
  if (!Number.isInteger(config.listenPort) || config.listenPort < 1 || config.listenPort > 65535) throw new Error('Invalid listen port');
  cleanDomain(config.publicDomain);
  const base = new URL(config.publicBaseUrl);
  const easyLocalHttp = config.mode === 'easy' && base.protocol === 'http:' && isDevelopmentLoopback(base.hostname);
  if (base.protocol !== 'https:' && !easyLocalHttp) {
    throw new Error('Public base URL must use HTTPS except for Easy Mode on development loopback');
  }
  if (config.federationMode !== 'disabled' && base.protocol !== 'https:') {
    throw new Error('Federation requires an HTTPS public base URL');
  }
  if (config.mode === 'production') {
    requireProductionSecret('admin token', config.adminToken, 32);
    if (!config.databaseUrl) throw new Error('Production mode requires LOOM_DATABASE_URL');
    if (!config.objectStore?.bucket || !config.objectStore.accessKeyId || !config.objectStore.secretAccessKey) throw new Error('Production mode requires S3-compatible object storage configuration');
    const database = new URL(config.databaseUrl);
    requireProductionSecret('database password', decodeURIComponent(database.password), 16);
    requireProductionSecret('S3 access key', config.objectStore.accessKeyId);
    requireProductionSecret('S3 secret', config.objectStore.secretAccessKey, 32);
    if (config.rtcTurnSharedSecret !== undefined) requireProductionSecret('TURN secret', config.rtcTurnSharedSecret, 32);
    const secrets = [config.adminToken, decodeURIComponent(database.password), config.objectStore.secretAccessKey, config.rtcTurnSharedSecret].filter(Boolean);
    if (new Set(secrets).size !== secrets.length) throw new Error('Production credentials must be independent');
  }
  if (!Number.isSafeInteger(config.maxAttachmentBytes) || config.maxAttachmentBytes < 29 || config.maxAttachmentBytes > 2 * 1024 ** 3 || !Number.isSafeInteger(config.maxRequestBytes) || config.maxRequestBytes < 1024 || config.maxRequestBytes > 16 * 1024 ** 2) throw new Error('Invalid request limits');
  if (config.publicResourceMetrics !== undefined && typeof config.publicResourceMetrics !== 'boolean') throw new Error('Invalid public metrics option');
  if (config.lanDiscoveryEnabled) {
    const lan = new URL(config.lanAdvertiseEndpoint ?? config.publicBaseUrl);
    if (lan.protocol !== 'https:') throw new Error('LAN discovery requires an HTTPS advertised endpoint');
  }

  const stun = config.rtcStunUrls ?? [];
  const turn = config.rtcTurnUrls ?? [];
  if (stun.length > 16 || stun.some((url) => !validIceUrl(url, ['stun']))) {
    throw new Error('Invalid Loom STUN configuration');
  }
  if (turn.length > 16 || turn.some((url) => !validIceUrl(url, ['turn', 'turns']))) {
    throw new Error('Invalid Loom TURN configuration');
  }
  const ttl = config.rtcCredentialTtlSeconds ?? DEFAULT_RTC_CREDENTIAL_TTL_SECONDS;
  if (!Number.isInteger(ttl) || ttl < 60 || ttl > 3600) {
    throw new Error('TURN credential TTL must be between 60 and 3600 seconds');
  }
  if (config.callsEnabled && config.mode === 'production' && !config.groupCalls?.enabled) {
    if (turn.length === 0 || !config.rtcTurnSharedSecret || config.rtcTurnSharedSecret.length < 32) {
      throw new Error('Production calling requires TURN URLs and a TURN shared secret of at least 32 characters');
    }
  }
  if (config.rtcTurnSharedSecret?.includes('\n') || config.rtcTurnSharedSecret?.includes('\r')) {
    throw new Error('Invalid TURN shared secret');
  }
  if(config.groupCalls&&typeof config.groupCalls.enabled!=='boolean')throw new Error('Invalid group call enable flag');
  if(config.groupCalls?.enabled){
    const g=config.groupCalls,u=new URL(g.apiUrl);
    if(!['http:','https:'].includes(u.protocol)||u.username||u.password||u.search||u.hash||u.pathname!=='/')throw new Error('SFU API must be a private HTTP(S) origin');
    requireProductionSecret('SFU API key',g.apiKey,8);requireProductionSecret('SFU secret',g.apiSecret,32);
    if([config.adminToken,config.rtcTurnSharedSecret,config.objectStore?.secretAccessKey].includes(g.apiSecret))throw new Error('Group call credentials must be independent');
    if(!Number.isInteger(g.maxParticipants)||g.maxParticipants<2||g.maxParticipants>32)throw new Error('Group calls support 2–32 participants');
  }
}
function groupCallEnvironment():LoomNodeConfig['groupCalls']{
  if(process.env.LOOM_GROUP_CALLS_ENABLED===undefined)return undefined;
  return {enabled:process.env.LOOM_GROUP_CALLS_ENABLED==='true',apiUrl:process.env.LOOM_GROUP_CALLS_API_URL??'http://livekit:7880',apiKey:process.env.LOOM_GROUP_CALLS_API_KEY??'',apiSecret:process.env.LOOM_GROUP_CALLS_API_SECRET??'',maxParticipants:Number(process.env.LOOM_GROUP_CALLS_MAX_PARTICIPANTS??16)};
}

export function loadOrCreateConfig(path = configPathFromEnv()): { config: LoomNodeConfig; created: boolean; path: string } {
  try {
    const raw = readFileSync(path, 'utf8').replace(/^\uFEFF/, '');
    const parsed = JSON.parse(raw) as LoomNodeConfig;
    // Runtime environment overrides apply to existing persisted installations too.
    if (process.env.LOOM_MAX_ATTACHMENT_BYTES !== undefined) parsed.maxAttachmentBytes = Number(process.env.LOOM_MAX_ATTACHMENT_BYTES);
    if (process.env.LOOM_MAX_REQUEST_BYTES !== undefined) parsed.maxRequestBytes = Number(process.env.LOOM_MAX_REQUEST_BYTES);
    if (process.env.LOOM_PUBLIC_RESOURCE_METRICS !== undefined) parsed.publicResourceMetrics = process.env.LOOM_PUBLIC_RESOURCE_METRICS === 'true';
    if(process.env.LOOM_GROUP_CALLS_ENABLED!==undefined)parsed.groupCalls=groupCallEnvironment();
    for (const [env,field] of [['LOOM_CALLS_ENABLED','callsEnabled'],['LOOM_VOICE_CALLS_ENABLED','voiceCallsEnabled'],['LOOM_VIDEO_CALLS_ENABLED','videoCallsEnabled']] as const) {
      if(process.env[env]!==undefined)parsed[field]=process.env[env]==='true';
    }
    if(process.env.LOOM_TURN_URLS!==undefined)parsed.rtcTurnUrls=process.env.LOOM_TURN_URLS.split(',').map(s=>s.trim()).filter(Boolean);
    if(process.env.LOOM_STUN_URLS!==undefined)parsed.rtcStunUrls=process.env.LOOM_STUN_URLS.split(',').map(s=>s.trim()).filter(Boolean);
    if(process.env.LOOM_TURN_SHARED_SECRET!==undefined)parsed.rtcTurnSharedSecret=process.env.LOOM_TURN_SHARED_SECRET;
    validateConfig(parsed);
    return { config: parsed, created: false, path };
  } catch (error: unknown) {
    const code = typeof error === 'object' && error !== null && 'code' in error ? (error as { code?: string }).code : undefined;
    if (code !== 'ENOENT') throw error;
  }
  const config = createDefaultConfig();
  validateConfig(config);
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, JSON.stringify(config, null, 2) + '\n', { mode: 0o600 });
  return { config, created: true, path };
}


