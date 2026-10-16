import { createHash } from 'node:crypto';
import type { IncomingMessage, ServerResponse } from 'node:http';

export interface JsonRequestBody {
  value: Record<string, unknown>;
  bytes: Buffer;
  sha256: string;
}

export function json(response: ServerResponse, status: number, body: unknown, headers: Record<string, string> = {}): void {
  const encoded = Buffer.from(JSON.stringify(body));
  response.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'content-length': String(encoded.length), 'cache-control': 'no-store', 'x-content-type-options': 'nosniff', ...headers });
  response.end(encoded);
}

export function text(response: ServerResponse, status: number, body: string): void {
  response.writeHead(status, { 'content-type': 'text/plain; charset=utf-8', 'content-length': String(Buffer.byteLength(body)), 'cache-control': 'no-store' });
  response.end(body);
}

function verifyDeclaredBodyHash(request: IncomingMessage, actualSha256: string): void {
  const declared = request.headers['x-loom-content-sha256'];
  if (declared == null) return;
  if (typeof declared !== 'string' || !/^[0-9a-f]{64}$/i.test(declared.trim())) throw new Error('invalid_device_request_body_hash');
  if (declared.trim().toLowerCase() !== actualSha256) throw new Error('device_request_body_hash_mismatch');
}

export async function readJsonBody(request: IncomingMessage, maxBytes: number): Promise<JsonRequestBody> {
  const contentType = request.headers['content-type'] ?? '';
  if (!String(contentType).toLowerCase().startsWith('application/json')) throw new Error('content_type');
  let bytes = 0;
  const parts: Buffer[] = [];
  for await (const chunk of request) {
    const part = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    bytes += part.length;
    if (bytes > maxBytes) throw new Error('body_too_large');
    parts.push(part);
  }
  const raw = parts.length ? Buffer.concat(parts) : Buffer.alloc(0);
  const sha256 = createHash('sha256').update(raw).digest('hex');
  verifyDeclaredBodyHash(request, sha256);
  if (!raw.length) return { value: {}, bytes: raw, sha256 };
  const parsed = JSON.parse(raw.toString('utf8')) as unknown;
  if (!parsed || Array.isArray(parsed) || typeof parsed !== 'object') throw new Error('json_object_required');
  return { value: parsed as Record<string, unknown>, bytes: raw, sha256 };
}

export async function readJson(request: IncomingMessage, maxBytes: number): Promise<Record<string, unknown>> {
  return (await readJsonBody(request, maxBytes)).value;
}

export function bearerToken(request: IncomingMessage): string | null {
  const value = request.headers.authorization;
  if (!value?.startsWith('Bearer ')) return null;
  const token = value.slice(7).trim();
  return token || null;
}
