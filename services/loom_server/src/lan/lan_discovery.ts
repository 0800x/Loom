import dgram, { type RemoteInfo, type Socket } from 'node:dgram';
import { randomBytes } from 'node:crypto';
import type { LoomNodeConfig } from '../config/config.ts';
import { LoomNodeIdentity } from '../identity/node_identity.ts';

export const LOOM_LAN_MULTICAST_ADDRESS = '239.255.67.78';
export const LOOM_LAN_MULTICAST_PORT = 37483;
export const LOOM_LAN_DISCOVERY_QUERY = 'LOOM_DISCOVER_V1';

export interface LoomLanAnnouncement {
  schemaVersion: 1;
  nodeId: string;
  domain: string;
  endpoint: string;
  publicKey: string;
  fingerprint: string;
  timestamp: string;
  nonce: string;
  signature: string;
}

export function canonicalLanAnnouncement(value: Omit<LoomLanAnnouncement, 'signature'>): string {
  return [
    'loom-lan-announcement-v1',
    value.nodeId,
    value.domain,
    value.endpoint,
    value.publicKey,
    value.fingerprint,
    value.timestamp,
    value.nonce,
  ].join('\n');
}

export function createLanAnnouncement(config: LoomNodeConfig, identity: LoomNodeIdentity, now = new Date()): LoomLanAnnouncement {
  const endpoint = config.lanAdvertiseEndpoint ?? config.publicBaseUrl;
  const parsed = new URL(endpoint);
  if (parsed.protocol !== 'https:') throw new Error('LAN discovery only advertises HTTPS endpoints');
  const key = identity.publicInfo();
  const unsigned = {
    schemaVersion: 1 as const,
    nodeId: key.nodeId,
    domain: config.publicDomain,
    endpoint,
    publicKey: key.publicKey,
    fingerprint: key.fingerprint,
    timestamp: now.toISOString(),
    nonce: randomBytes(18).toString('base64url'),
  };
  return { ...unsigned, signature: identity.signUtf8(canonicalLanAnnouncement(unsigned)) };
}

export class LoomLanDiscoveryResponder {
  private socket: Socket | null = null;
  private readonly config: LoomNodeConfig;
  private readonly identity: LoomNodeIdentity;

  constructor(config: LoomNodeConfig, identity: LoomNodeIdentity) {
    this.config = config;
    this.identity = identity;
  }

  async start(): Promise<void> {
    if (!this.config.lanDiscoveryEnabled || this.socket) return;
    const socket = dgram.createSocket({ type: 'udp4', reuseAddr: true });
    this.socket = socket;
    socket.on('message', (message, remote) => this.onMessage(message, remote));
    socket.on('error', (error) => console.warn('[loom-node] LAN discovery error:', error.message));
    await new Promise<void>((resolve, reject) => {
      socket.once('error', reject);
      socket.bind(LOOM_LAN_MULTICAST_PORT, '0.0.0.0', () => {
        socket.off('error', reject);
        try {
          socket.addMembership(LOOM_LAN_MULTICAST_ADDRESS);
          socket.setMulticastTTL(1);
          resolve();
        } catch (error) { reject(error); }
      });
    });
  }

  private onMessage(message: Buffer, remote: RemoteInfo): void {
    if (!this.socket || message.length > 128 || message.toString('utf8') !== LOOM_LAN_DISCOVERY_QUERY) return;
    try {
      const response = Buffer.from(JSON.stringify(createLanAnnouncement(this.config, this.identity)), 'utf8');
      if (response.length > 8192) return;
      this.socket.send(response, remote.port, remote.address);
    } catch (error) {
      console.warn('[loom-node] LAN discovery response skipped:', error instanceof Error ? error.message : error);
    }
  }

  async close(): Promise<void> {
    const socket = this.socket;
    this.socket = null;
    if (!socket) return;
    await new Promise<void>((resolve) => socket.close(() => resolve()));
  }
}
