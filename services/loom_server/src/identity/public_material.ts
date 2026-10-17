import { createHash, createPublicKey, verify } from 'node:crypto';

export interface IdentityPublicMaterial {
  identityId: string;
  publicKey: string;
  fingerprint: string;
}

export function decodeCanonicalBase64(value: string, expectedBytes: number, error = 'invalid_identity'): Buffer {
  const cleaned = value.trim();
  if (!/^[A-Za-z0-9+/]+={0,2}$/.test(cleaned)) throw new Error(error);
  const decoded = Buffer.from(cleaned, 'base64');
  if (decoded.length !== expectedBytes || decoded.toString('base64') !== cleaned) throw new Error(error);
  return decoded;
}

export function fingerprintForBytes(bytes: Buffer): string {
  const hex = createHash('sha256').update(bytes).digest('hex').toUpperCase();
  return hex.match(/.{1,4}/g)?.join(' ') ?? hex;
}

export function identityIdForPublicKey(publicKeyBase64: string): string {
  const raw = decodeCanonicalBase64(publicKeyBase64, 32);
  return `chn:${createHash('sha256').update(raw).digest('base64url')}`;
}

export function validateIdentityPublicMaterial(input: IdentityPublicMaterial): IdentityPublicMaterial {
  const publicKey = input.publicKey.trim();
  const raw = decodeCanonicalBase64(publicKey, 32);
  const identityId = `chn:${createHash('sha256').update(raw).digest('base64url')}`;
  const fingerprint = fingerprintForBytes(raw);
  if (input.identityId.trim() !== identityId || input.fingerprint.trim().toUpperCase() !== fingerprint) {
    throw new Error('invalid_identity');
  }
  return { identityId, publicKey, fingerprint };
}

export function verifyRawEd25519(payload: Buffer, signatureBase64: string, publicKeyBase64: string): boolean {
  try {
    const raw = decodeCanonicalBase64(publicKeyBase64, 32, 'invalid_public_key');
    const signature = decodeCanonicalBase64(signatureBase64, 64, 'invalid_signature');
    const key = createPublicKey({
      key: Buffer.concat([Buffer.from('302a300506032b6570032100', 'hex'), raw]),
      format: 'der',
      type: 'spki',
    });
    return verify(null, payload, key, signature);
  } catch {
    return false;
  }
}
