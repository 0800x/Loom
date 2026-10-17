import type { IncomingMessage, ServerResponse } from 'node:http';
import type { Readable } from 'node:stream';
import { pipeline } from 'node:stream/promises';

export interface EncryptedAttachmentReader {
  read(id: string): Promise<{ bytes: number; body: Readable } | null>;
}

/** URL is a 256-bit capability carried inside E2EE. No attachment key,
 * MIME/filename, credentials or plaintext is exposed by this endpoint. */
export async function serveEncryptedAttachment(request: IncomingMessage, response: ServerResponse, pathname: string, store: EncryptedAttachmentReader): Promise<boolean> {
  const match = /^\/api\/v1\/attachments\/(att_[a-f0-9]{64})$/.exec(pathname);
  if (request.method !== 'GET' || !match) return false;
  const stored = await store.read(match[1]);
  if (!stored) {
    response.writeHead(404, { 'content-type': 'application/json', 'cache-control': 'no-store' });
    response.end('{"error":"attachment_not_found"}');
    return true;
  }
  response.writeHead(200, { 'content-type': 'application/octet-stream', 'content-length': stored.bytes, 'cache-control': 'no-store', 'x-content-type-options': 'nosniff', 'content-disposition': 'attachment' });
  try { await pipeline(stored.body, response); }
  catch { response.destroy(); }
  return true;
}
