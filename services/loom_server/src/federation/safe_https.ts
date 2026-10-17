import { lookup } from 'node:dns/promises';
import { request as httpsRequest, type RequestOptions } from 'node:https';
import { isIP, type LookupFunction } from 'node:net';
import type { TLSSocket } from 'node:tls';
import type { IncomingHttpHeaders } from 'node:http';

export interface SafeFederationHttpsResponse {
  status: number;
  headers: IncomingHttpHeaders;
  body: Buffer;
}

export interface SafeFederationHttpsOptions {
  method?: string;
  headers?: Record<string, string>;
  body?: string | Buffer;
  timeoutMs?: number;
  maxBytes?: number;
  allowPrivate?: boolean;
}

type ResolvedAddress = { address: string; family: 4 | 6 };

type MultiAddressRequestOptions = RequestOptions & {
  autoSelectFamily?: boolean;
  autoSelectFamilyAttemptTimeout?: number;
};

export function unbracketHostname(value: string): string {
  return value.startsWith('[') && value.endsWith(']')
    ? value.slice(1, -1)
    : value;
}

function normalizedIp(value: string | undefined): string {
  return unbracketHostname((value ?? '').replace(/^::ffff:/, '')).toLowerCase();
}

function safeCallerHeaders(input: Record<string, string> | undefined): Record<string, string> {
  const output: Record<string, string> = {};
  for (const [name, value] of Object.entries(input ?? {})) {
    const lower = name.toLowerCase();
    // These fields are transport/security invariants and must not be supplied by
    // a federation caller. Content-Type/Accept and application headers remain
    // caller-controlled.
    if (lower === 'host' ||
        lower === 'content-length' ||
        lower === 'transfer-encoding' ||
        lower === 'connection') {
      continue;
    }
    output[name] = value;
  }
  return output;
}

export function isPrivateOrLocalIp(value: string): boolean {
  const address = normalizedIp(value);
  if (address === '::1' || address === '::' || address === '0.0.0.0') return true;
  if (isIP(address) === 4) {
    const octets = address.split('.').map(Number);
    const [a, b, c] = octets;
    return a === 0 ||
      a === 10 ||
      a === 127 ||
      (a === 100 && b >= 64 && b <= 127) ||
      (a === 169 && b === 254) ||
      (a === 172 && b >= 16 && b <= 31) ||
      (a === 192 && b === 0 && c === 0) ||
      (a === 192 && b === 0 && c === 2) ||
      (a === 192 && b === 168) ||
      (a === 198 && (b === 18 || b === 19)) ||
      (a === 198 && b === 51 && c === 100) ||
      (a === 203 && b === 0 && c === 113) ||
      a >= 224;
  }
  if (isIP(address) === 6) {
    return address.startsWith('fc') ||
      address.startsWith('fd') ||
      /^fe[89ab]/.test(address) ||
      address.startsWith('ff') ||
      address.startsWith('2001:db8:');
  }
  return false;
}

export async function resolveFederationHost(
  hostnameValue: string,
  allowPrivate = false,
): Promise<ResolvedAddress[]> {
  const hostname = unbracketHostname(hostnameValue.trim().toLowerCase());
  if (!hostname || hostname.length > 253 || /[\r\n\0]/.test(hostname)) {
    throw new Error('invalid_federation_hostname');
  }
  if ((hostname === 'localhost' || hostname.endsWith('.localhost')) && !allowPrivate) {
    throw new Error('federation_private_endpoint_rejected');
  }
  let answers: ResolvedAddress[];
  const literalFamily = isIP(hostname);
  if (literalFamily === 4 || literalFamily === 6) {
    answers = [{ address: hostname, family: literalFamily }];
  } else {
    const resolved = await lookup(hostname, { all: true, verbatim: true });
    answers = resolved
      .filter((answer): answer is { address: string; family: 4 | 6 } => answer.family === 4 || answer.family === 6)
      .map((answer) => ({ address: answer.address, family: answer.family }));
  }
  if (!answers.length) throw new Error('federation_dns_resolution_failed');
  if (!allowPrivate && answers.some((answer) => isPrivateOrLocalIp(answer.address))) {
    throw new Error('federation_private_endpoint_rejected');
  }
  const unique = new Map<string, ResolvedAddress>();
  for (const answer of answers) unique.set(`${answer.family}:${normalizedIp(answer.address)}`, answer);
  return [...unique.values()];
}

export async function safeFederationHttpsRequest(
  urlValue: string,
  options: SafeFederationHttpsOptions = {},
): Promise<SafeFederationHttpsResponse> {
  const url = new URL(urlValue);
  if (url.protocol !== 'https:' || url.username || url.password || url.hash) {
    throw new Error('invalid_federation_https_endpoint');
  }

  const body = options.body == null
    ? Buffer.alloc(0)
    : Buffer.isBuffer(options.body)
      ? options.body
      : Buffer.from(options.body, 'utf8');
  const maxBytes = Math.max(1, Math.min(options.maxBytes ?? 256 * 1024, 4 * 1024 * 1024));
  const timeoutMs = Math.max(500, Math.min(options.timeoutMs ?? 8_000, 30_000));
  const method = (options.method ?? 'GET').toUpperCase();
  const dialHostname = unbracketHostname(url.hostname);

  // The deadline starts before DNS. request.setTimeout() is only an inactivity
  // timeout after a socket exists and therefore cannot bound DNS or the total
  // wall-clock request duration.
  return new Promise<SafeFederationHttpsResponse>((resolve, reject) => {
    let settled = false;
    let request: ReturnType<typeof httpsRequest> | undefined;
    const deadline = setTimeout(() => {
      request?.destroy();
      finishReject(new Error('federation_request_timeout'));
    }, timeoutMs);
    deadline.unref?.();

    const finishReject = (error: Error) => {
      if (settled) return;
      settled = true;
      clearTimeout(deadline);
      reject(error);
    };
    const finishResolve = (value: SafeFederationHttpsResponse) => {
      if (settled) return;
      settled = true;
      clearTimeout(deadline);
      resolve(value);
    };

    void (async () => {
      const addresses = await resolveFederationHost(
        dialHostname,
        options.allowPrivate === true,
      );
      if (settled) return;
      const selected = addresses[0];
      const allowedAddresses = new Set(
        addresses.map((answer) => normalizedIp(answer.address)),
      );
      const lookupPinned: LookupFunction = (_hostname, lookupOptions, callback) => {
        if (typeof lookupOptions === 'object' && lookupOptions.all) {
          callback(null, addresses.map((answer) => ({
            address: answer.address,
            family: answer.family,
          })));
          return;
        }
        callback(null, selected.address, selected.family);
      };

      const callerHeaders = safeCallerHeaders(options.headers);
      const requestOptions: MultiAddressRequestOptions = {
        protocol: 'https:',
        hostname: dialHostname,
        port: url.port ? Number(url.port) : 443,
        method,
        path: `${url.pathname}${url.search}`,
        servername: isIP(dialHostname) ? undefined : dialHostname,
        rejectUnauthorized: true,
        lookup: lookupPinned,
        autoSelectFamily: addresses.length > 1,
        autoSelectFamilyAttemptTimeout: 250,

        // Do not use https.globalAgent here. Node's keep-alive pool may hand a
        // request an already-secure socket, in which case secureConnect does not
        // fire again and a per-request DNS pin check can be bypassed. A future
        // federation pool must be keyed by the validated address-set generation
        // and validate reused remoteAddress explicitly.
        agent: false,
        headers: {
          'user-agent': 'Loom-Federation/1',
          ...callerHeaders,
          host: url.host,
          ...(body.length > 0 ? { 'content-length': String(body.length) } : {}),
        },
      };

      request = httpsRequest(requestOptions, (response) => {
        const declared = Number(response.headers['content-length'] ?? 0);
        if (Number.isFinite(declared) && declared > maxBytes) {
          response.destroy();
          request?.destroy();
          finishReject(new Error('federation_response_too_large'));
          return;
        }
        const chunks: Buffer[] = [];
        let total = 0;
        response.on('data', (chunk: Buffer | string) => {
          const bytes = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
          total += bytes.length;
          if (total > maxBytes) {
            response.destroy();
            request?.destroy();
            finishReject(new Error('federation_response_too_large'));
            return;
          }
          chunks.push(bytes);
        });
        response.on('end', () => {
          finishResolve({
            status: response.statusCode ?? 0,
            headers: response.headers,
            body: Buffer.concat(chunks),
          });
        });
        response.on('error', (error) => finishReject(error));
      });

      request.on('socket', (socket) => {
        const tlsSocket = socket as TLSSocket;
        const validateConnectedAddress = () => {
          const actual = normalizedIp(tlsSocket.remoteAddress);
          if (!actual || !allowedAddresses.has(actual)) {
            request?.destroy(new Error('federation_connected_address_mismatch'));
          }
        };
        if (tlsSocket.remoteAddress && !tlsSocket.connecting && !tlsSocket.secureConnecting) {
          validateConnectedAddress();
        } else {
          tlsSocket.once('secureConnect', validateConnectedAddress);
        }
      });
      request.on('error', (error) => finishReject(error));
      if (body.length > 0) request.write(body);
      request.end();
    })().catch((error: unknown) => {
      finishReject(error instanceof Error ? error : new Error(String(error)));
    });
  });
}
