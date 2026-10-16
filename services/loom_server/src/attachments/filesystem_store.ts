import { createHash, randomBytes } from 'node:crypto';
import { accessSync, constants, createReadStream, createWriteStream, mkdirSync, renameSync, rmSync, statSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import type { IncomingMessage } from 'node:http';
import { finished } from 'node:stream/promises';

export interface StoredAttachment {
  id: string;
  bytes: number;
  sha256: string;
  path: string;
}

export interface AttachmentHealth {
  ready: boolean;
  backend: 'filesystem' | 's3';
  latencyMs: number;
  detail?: string;
}

export class FilesystemAttachmentStore {
  private readonly root: string;
  private readonly maxBytes: number;

  constructor(root: string, maxBytes: number) {
    this.root = root;
    this.maxBytes = maxBytes;
    mkdirSync(root, { recursive: true });
  }

  async health(): Promise<AttachmentHealth> {
    const started = Date.now();
    try {
      const stat = statSync(this.root);
      if (!stat.isDirectory()) throw new Error('attachment_root_not_directory');
      accessSync(this.root, constants.R_OK | constants.W_OK);
      return { ready: true, backend: 'filesystem', latencyMs: Date.now() - started };
    } catch (error) {
      return {
        ready: false,
        backend: 'filesystem',
        latencyMs: Date.now() - started,
        detail: error instanceof Error ? error.message : String(error),
      };
    }
  }

  // A random 256-bit capability names encrypted bytes only. Its URL is sent
  // inside E2EE, so devices on another Home Node need no foreign credentials.
  async read(id: string): Promise<{ bytes: number; body: import('node:stream').Readable } | null> {
    if (!/^att_[a-f0-9]{64}$/.test(id)) return null;
    const path = resolve(this.root, id);
    try {
      const stat = statSync(path);
      if (!stat.isFile() || stat.size > this.maxBytes) return null;
      return { bytes: stat.size, body: createReadStream(path) };
    } catch { return null; }
  }

  async store(request: IncomingMessage): Promise<StoredAttachment> {
    const id = `att_${randomBytes(32).toString('hex')}`;
    const finalPath = resolve(this.root, id);
    const tempPath = `${finalPath}.partial`;
    mkdirSync(dirname(finalPath), { recursive: true });
    const hash = createHash('sha256');
    let bytes = 0;
    const stream = createWriteStream(tempPath, { flags: 'wx', mode: 0o600 });
    try {
      for await (const chunk of request) {
        const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
        bytes += buffer.length;
        if (bytes > this.maxBytes) throw new Error('attachment_too_large');
        hash.update(buffer);
        if (!stream.write(buffer)) await new Promise<void>((resolveDrain) => stream.once('drain', resolveDrain));
      }
      stream.end();
      await finished(stream);
      renameSync(tempPath, finalPath);
      return { id, bytes: statSync(finalPath).size, sha256: hash.digest('hex'), path: finalPath };
    } catch (error) {
      stream.destroy();
      // Opening is asynchronous. Wait for its file descriptor to close before
      // unlinking, otherwise a late open can recreate a rejected upload.
      await finished(stream).catch(() => {});
      rmSync(tempPath, { force: true });
      throw error;
    }
  }
}

