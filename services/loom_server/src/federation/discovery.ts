import { lookup } from 'node:dns/promises';
import { isIP } from 'node:net';
import { normalizeLoomDomain } from './address.ts';
import { verifyDiscovery, type FederationDiscovery } from './protocol.ts';
import { safeFederationHttpsRequest } from './safe_https.ts';

export interface VerifiedRemoteNode {
  nodeId: string;
  domain: string;
  endpoint: string;
  publicKey: string;
  fingerprint: string;
  protocolVersion: string;
  latencyMs: number;
}

function privateIp(value: string): boolean {
  const address = value.replace(/^::ffff:/, '').toLowerCase();
  if (address === '::1') return true;
  if (isIP(address) === 4) {
    const [a, b] = address.split('.').map(Number);
    return a === 10 ||
      a === 127 ||
      a === 0 ||
      (a === 169 && b === 254) ||
      (a === 172 && b >= 16 && b <= 31) ||
      (a === 192 && b === 168);
  }
  return address.startsWith('fc') ||
    address.startsWith('fd') ||
    /^fe[89ab]/.test(address) ||
    address === '::';
}

async function assertPublicHostname(hostname: string): Promise<void> {
  if (hostname === 'localhost' || hostname.endsWith('.localhost')) {
    throw new Error('federation_private_endpoint_rejected');
  }
  if (isIP(hostname)) {
    if (privateIp(hostname)) throw new Error('federation_private_endpoint_rejected');
    return;
  }
  const answers = await lookup(hostname, { all: true, verbatim: true });
  if (!answers.length || answers.some((answer) => privateIp(answer.address))) {
    throw new Error('federation_private_endpoint_rejected');
  }
}

async function readJsonLimited(response: Response, maxBytes: number): Promise<unknown> {
  const declared = Number(response.headers.get('content-length') ?? 0);
  if (Number.isFinite(declared) && declared > maxBytes) {
    throw new Error('federation_discovery_too_large');
  }
  if (!response.body) throw new Error('empty_federation_discovery');
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > maxBytes) {
      await reader.cancel();
      throw new Error('federation_discovery_too_large');
    }
    chunks.push(value);
  }
  return JSON.parse(Buffer.concat(chunks).toString('utf8'));
}

export async function discoverRemoteNode(
  domainValue: string,
  options: { allowPrivate?: boolean; timeoutMs?: number; fetchImpl?: typeof fetch } = {},
): Promise<VerifiedRemoteNode> {
  const domain = normalizeLoomDomain(domainValue);
  const origin = new URL(`https://${domain}`);
  const timeoutMs = options.timeoutMs ?? 7000;
  const allowPrivate = options.allowPrivate === true;
  const started = Date.now();
  let input: FederationDiscovery;

  if (options.fetchImpl) {
    if (!allowPrivate) await assertPublicHostname(origin.hostname);
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    try {
      const response = await options.fetchImpl(
        `${origin.origin}/.well-known/loom/server`,
        {
          method: 'GET',
          signal: controller.signal,
          redirect: 'error',
          headers: {
            accept: 'application/json',
            'user-agent': 'Loom-Federation/1',
          },
        },
      );
      if (!response.ok) throw new Error(`federation_discovery_http_${response.status}`);
      input = await readJsonLimited(response, 64 * 1024) as FederationDiscovery;
    } finally {
      clearTimeout(timer);
    }
  } else {
    const response = await safeFederationHttpsRequest(
      `${origin.origin}/.well-known/loom/server`,
      {
        method: 'GET',
        headers: { accept: 'application/json' },
        timeoutMs,
        maxBytes: 64 * 1024,
        allowPrivate,
      },
    );
    if (response.status < 200 || response.status >= 300) {
      throw new Error(`federation_discovery_http_${response.status}`);
    }
    try {
      input = JSON.parse(response.body.toString('utf8')) as FederationDiscovery;
    } catch {
      throw new Error('invalid_federation_discovery_json');
    }
  }

  const verified = verifyDiscovery(input);
  const endpoint = new URL(verified.endpoint);
  if (endpoint.protocol !== 'https:' ||
      endpoint.hostname.toLowerCase() !== origin.hostname.toLowerCase()) {
    throw new Error('federation_endpoint_mismatch');
  }
  if (options.fetchImpl && !allowPrivate) await assertPublicHostname(endpoint.hostname);
  return {
    ...verified,
    domain,
    protocolVersion: input.protocol,
    latencyMs: Date.now() - started,
  };
}
