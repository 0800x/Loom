import { createHash, randomBytes } from 'node:crypto';
import type { IncomingMessage } from 'node:http';
import type { AttachmentHealth, StoredAttachment } from './filesystem_store.ts';

export interface S3AttachmentConfig { endpoint?: string; region: string; bucket: string; accessKeyId: string; secretAccessKey: string; forcePathStyle?: boolean; }

export class S3AttachmentStore {
  private readonly client: unknown;
  private readonly bucket: string;
  private readonly maxBytes: number;

  private constructor(privateClient: unknown, bucket: string, maxBytes: number) {
    this.client = privateClient;
    this.bucket = bucket;
    this.maxBytes = maxBytes;
  }

  static async create(config: S3AttachmentConfig, maxBytes: number): Promise<S3AttachmentStore> {
    const sdk = await import('@aws-sdk/client-s3') as unknown as { S3Client: new (config: Record<string, unknown>) => unknown };
    const client = new sdk.S3Client({ endpoint: config.endpoint, region: config.region, forcePathStyle: config.forcePathStyle ?? Boolean(config.endpoint), credentials: { accessKeyId: config.accessKeyId, secretAccessKey: config.secretAccessKey } });
    return new S3AttachmentStore(client, config.bucket, maxBytes);
  }

  async health(): Promise<AttachmentHealth & { bucket: string }> {
    const started = Date.now();
    try {
      const sdk = await import('@aws-sdk/client-s3') as unknown as { HeadBucketCommand: new (input: Record<string, unknown>) => unknown };
      const client = this.client as { send(command: unknown): Promise<unknown> };
      await client.send(new sdk.HeadBucketCommand({ Bucket: this.bucket }));
      return { ready: true, backend: 's3', bucket: this.bucket, latencyMs: Date.now() - started };
    } catch (error) {
      return {
        ready: false,
        backend: 's3',
        bucket: this.bucket,
        latencyMs: Date.now() - started,
        detail: error instanceof Error ? error.message : String(error),
      };
    }
  }

  async read(id: string): Promise<{ bytes: number; body: import('node:stream').Readable } | null> {
    if (!/^att_[a-f0-9]{64}$/.test(id)) return null;
    const sdk = await import('@aws-sdk/client-s3') as unknown as { GetObjectCommand: new (input: Record<string, unknown>) => unknown };
    const client = this.client as { send(command: unknown): Promise<{ Body: import('node:stream').Readable; ContentLength: number }> };
    try {
      const value = await client.send(new sdk.GetObjectCommand({ Bucket: this.bucket, Key: id }));
      if (!value.Body || !Number.isSafeInteger(value.ContentLength) || value.ContentLength > this.maxBytes) { value.Body?.destroy(); return null; }
      return { bytes: value.ContentLength, body: value.Body };
    } catch (error) {
      if ((error as { name?: string }).name === 'NoSuchKey') return null;
      throw error;
    }
  }

  async store(request: IncomingMessage): Promise<StoredAttachment> {
    const chunks: Buffer[] = [];
    let bytes = 0;
    const hash = createHash('sha256');
    for await (const chunk of request) {
      const b = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
      bytes += b.length;
      if (bytes > this.maxBytes) throw new Error('attachment_too_large');
      chunks.push(b);
      hash.update(b);
    }
    const id = `att_${randomBytes(32).toString('hex')}`;
    const body = Buffer.concat(chunks);
    const sdk = await import('@aws-sdk/client-s3') as unknown as { PutObjectCommand: new (input: Record<string, unknown>) => unknown };
    const client = this.client as { send(command: unknown): Promise<unknown> };
    await client.send(new sdk.PutObjectCommand({ Bucket: this.bucket, Key: id, Body: body, ContentType: 'application/octet-stream', Metadata: { sha256: hash.digest('hex') } }));
    const digest = createHash('sha256').update(body).digest('hex');
    return { id, bytes, sha256: digest, path: `s3://${this.bucket}/${id}` };
  }
}

