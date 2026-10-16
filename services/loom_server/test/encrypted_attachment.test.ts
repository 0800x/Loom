import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Readable } from 'node:stream';
import { createServer, type IncomingMessage } from 'node:http';
import { createCipheriv, createDecipheriv, randomBytes, createHash } from 'node:crypto';
import { FilesystemAttachmentStore } from '../src/attachments/filesystem_store.ts';
import { serveEncryptedAttachment } from '../src/attachments/download.ts';

async function fixture(run: (store: FilesystemAttachmentStore, directory: string) => Promise<void>, max = 1024) {
  const directory = await mkdtemp(join(tmpdir(), 'loom-attachment-test-'));
  try { await run(new FilesystemAttachmentStore(directory, max), directory); }
  finally { await rm(directory, { recursive: true, force: true }); }
}
function upload(bytes: Buffer) { return Readable.from([bytes]) as unknown as IncomingMessage; }

test('random capability returns identical authenticated ciphertext over HTTP', async () => fixture(async (store, directory) => {
  const key = randomBytes(32), iv = randomBytes(12);
  const clear = Buffer.from('private image fixture');
  const cipher = createCipheriv('aes-256-gcm', key, iv);
  cipher.setAAD(Buffer.from('loom.media.v1'));
  const bytes = Buffer.concat([iv, cipher.update(clear), cipher.final(), cipher.getAuthTag()]);
  const stored = await store.store(upload(bytes));
  assert.match(stored.id, /^att_[a-f0-9]{64}$/);
  assert.equal(stored.sha256, createHash('sha256').update(bytes).digest('hex'));
  assert.deepEqual(await readFile(join(directory, stored.id)), bytes);
  assert.equal(bytes.includes(clear), false);
  const server = createServer(async (request, response) => {
    if (!await serveEncryptedAttachment(request, response, new URL(request.url!, 'http://local').pathname, store)) { response.writeHead(404); response.end(); }
  });
  await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve));
  try {
    const port = (server.address() as { port: number }).port;
    const response = await fetch(`http://127.0.0.1:${port}/api/v1/attachments/${stored.id}`);
    assert.equal(response.status, 200);
    assert.equal(response.headers.get('cache-control'), 'no-store');
    assert.equal(response.headers.get('content-type'), 'application/octet-stream');
    assert.equal(response.headers.get('x-content-type-options'), 'nosniff');
    const received = Buffer.from(await response.arrayBuffer());
    assert.deepEqual(received, bytes);
    const decipher = createDecipheriv('aes-256-gcm', key, received.subarray(0, 12));
    decipher.setAAD(Buffer.from('loom.media.v1')); decipher.setAuthTag(received.subarray(-16));
    assert.deepEqual(Buffer.concat([decipher.update(received.subarray(12, -16)), decipher.final()]), clear);
    assert.equal((await fetch(`http://127.0.0.1:${port}/api/v1/attachments/att_${'0'.repeat(64)}`)).status, 404);
    assert.equal((await fetch(`http://127.0.0.1:${port}/api/v1/attachments/${stored.id}`, { method: 'POST' })).status, 404);
  } finally { await new Promise<void>((resolve, reject) => server.close(error => error ? reject(error) : resolve())); }
}));

test('new upload uses independent capabilities', async () => fixture(async store => {
  const one = await store.store(upload(Buffer.from('ciphertext'))), two = await store.store(upload(Buffer.from('ciphertext')));
  assert.notEqual(one.id, two.id);
}));
test('path traversal and malformed IDs cannot open a file', async () => fixture(async store => {
  for (const id of ['../secret', '/etc/passwd', 'att_../secret', `att_${'a'.repeat(63)}`, `att_${'a'.repeat(65)}`, `att_${'A'.repeat(64)}`]) assert.equal(await store.read(id), null);
}));
test('oversized upload removes partial files', async () => fixture(async (store, directory) => {
  for (let attempt = 0; attempt < 50; attempt++) {
    await assert.rejects(store.store(upload(Buffer.alloc(9))), /attachment_too_large/);
    assert.deepEqual(await readdir(directory), []);
  }
}, 8));
