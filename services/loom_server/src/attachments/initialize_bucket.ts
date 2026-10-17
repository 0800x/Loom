import { pathToFileURL } from 'node:url';
import { resolve } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';

// Dedicated Compose initialization task. No identity/configuration files are used.
export async function ensureAttachmentBucket(send: (kind: 'head' | 'create') => Promise<unknown>, wait = () => delay(1000)): Promise<void> {
  for (let attempt = 0; attempt < 90; attempt++) {
    try {
      await send('head');
      return;
    } catch (error) {
      const status = (error as { $metadata?: { httpStatusCode?: number } }).$metadata?.httpStatusCode;
      const name = (error as { name?: string }).name;
      if (status === 401 || status === 403 || name === 'InvalidAccessKeyId' || name === 'SignatureDoesNotMatch') {
        throw new Error('Attachment storage rejected its configured credentials');
      }
      if (status === 404 || name === 'NoSuchBucket' || name === 'NotFound') {
        try { await send('create'); return; }
        catch (creation) {
          if ((creation as { name?: string }).name === 'BucketAlreadyOwnedByYou') return;
          throw new Error('Attachment bucket could not be created with the configured credentials');
        }
      }
      if (status !== undefined && status < 500) throw new Error('Attachment storage returned an unexpected response');
      if (attempt === 89) throw new Error('Attachment storage did not become reachable');
      await wait();
    }
  }
}

async function main(): Promise<void> {
  const { S3Client, HeadBucketCommand, CreateBucketCommand } = await import('@aws-sdk/client-s3');
  const bucket = process.env.LOOM_S3_BUCKET;
  const accessKeyId = process.env.LOOM_S3_ACCESS_KEY_ID;
  const secretAccessKey = process.env.LOOM_S3_SECRET_ACCESS_KEY;
  if (!bucket || !accessKeyId || !secretAccessKey) throw new Error('Attachment initialization credentials are missing');
  const client = new S3Client({ endpoint: process.env.LOOM_S3_ENDPOINT, region: process.env.LOOM_S3_REGION ?? 'us-east-1',
    forcePathStyle: process.env.LOOM_S3_FORCE_PATH_STYLE === 'true', maxAttempts: 1,
    credentials: { accessKeyId, secretAccessKey } });
  try {
    await ensureAttachmentBucket(kind => client.send(kind === 'head' ? new HeadBucketCommand({ Bucket: bucket }) : new CreateBucketCommand({ Bucket: bucket })));
    console.log('Attachment bucket is ready');
  } finally { client.destroy(); }
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main().catch(() => { console.error('Attachment initialization failed; check storage connectivity and saved credentials'); process.exitCode = 1; });
}
