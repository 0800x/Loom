import { randomUUID } from 'node:crypto';
import { inflateSync } from 'node:zlib';

export interface PublicAvatar { png: string | null; color: number }
export interface ProfileUpdate { displayName: string; avatar: PublicAvatar }

// Public presentation data, never key material. Only bounded PNGs are accepted;
// SVG/HTML/remote URLs are deliberately outside this endpoint's format.
export function validateAvatar(input: unknown): PublicAvatar {
  if (!input || typeof input !== 'object' || Array.isArray(input) ||
      Object.keys(input).some(key => !['png', 'color'].includes(key))) throw new Error('invalid_profile_avatar');
  const { png, color } = input as Record<string, unknown>;
  if (!Number.isInteger(color) || Number(color) < 0 || Number(color) > 5) throw new Error('invalid_profile_avatar');
  if (png === null) return { png: null, color: Number(color) };
  if (typeof png !== 'string' || png.length > 450_000) throw new Error('invalid_profile_avatar');
  const bytes = Buffer.from(png, 'base64');
  if (bytes.length < 45 || bytes.toString('base64') !== png ||
      !bytes.subarray(0, 8).equals(Buffer.from([137,80,78,71,13,10,26,10])) ||
      bytes.toString('ascii', 12, 16) !== 'IHDR' || bytes.readUInt32BE(8) !== 13 ||
      bytes.readUInt32BE(16) < 1 || bytes.readUInt32BE(16) > 256 ||
      bytes.readUInt32BE(20) < 1 || bytes.readUInt32BE(20) > 256) {
    throw new Error('invalid_profile_avatar');
  }
  // No animation, embedded text, EXIF, or unknown chunks. Validate CRCs and a
  // complete stream so malformed public images cannot become persistent data.
  let offset = 8, hasData = false, ended = false, hasSignificantBits = false;
  const chunks: Buffer[] = [];
  while (offset + 12 <= bytes.length) {
    const length = bytes.readUInt32BE(offset);
    if (length > bytes.length - offset - 12) throw new Error('invalid_profile_avatar');
    const type = bytes.toString('ascii', offset + 4, offset + 8);
    if (!['IHDR','IDAT','IEND','PLTE','tRNS','sRGB','gAMA','cHRM','sBIT'].includes(type) ||
        (type === 'IHDR' && offset !== 8)) throw new Error('invalid_profile_avatar');
    let crc = 0xffffffff;
    for (const byte of bytes.subarray(offset + 4, offset + 8 + length)) {
      crc ^= byte;
      for (let bit = 0; bit < 8; bit++) crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0);
    }
    if (((crc ^ 0xffffffff) >>> 0) !== bytes.readUInt32BE(offset + 8 + length)) throw new Error('invalid_profile_avatar');
    // Flutter/Skia writes sBIT even for its normalized 8-bit PNGs. It describes
    // channel precision, not user metadata; rejecting it rejected real photos.
    if (type === 'sBIT') {
      const channels = new Map([[0,1],[2,3],[3,3],[4,2],[6,4]]).get(bytes[25]);
      if (hasSignificantBits || hasData || !channels || length !== channels ||
          bytes.subarray(offset + 8, offset + 8 + length).some(bit => bit < 1 || bit > 8)) {
        throw new Error('invalid_profile_avatar');
      }
      hasSignificantBits = true;
    }
    if (type === 'IDAT') { hasData = true; chunks.push(bytes.subarray(offset + 8, offset + 8 + length)); }
    offset += length + 12;
    if (type === 'IEND') { ended = length === 0 && offset === bytes.length; break; }
  }
  if (!hasData || !ended) throw new Error('invalid_profile_avatar');
  // The client normalizes to non-interlaced 8-bit PNG. Bound inflation as well
  // as dimensions, so a tiny header cannot hide an oversized compressed stream.
  const channels = new Map([[0,1],[2,3],[3,1],[4,2],[6,4]]).get(bytes[25]);
  if (!channels || bytes[24] !== 8 || bytes[26] !== 0 || bytes[27] !== 0 || bytes[28] !== 0) throw new Error('invalid_profile_avatar');
  const rowLength = bytes.readUInt32BE(16) * channels + 1;
  const expectedLength = rowLength * bytes.readUInt32BE(20);
  try {
    const pixels = inflateSync(Buffer.concat(chunks), {maxOutputLength: expectedLength});
    if (pixels.length !== expectedLength) throw new Error('invalid_scanlines');
    for (let row = 0; row < pixels.length; row += rowLength) {
      if (pixels[row] > 4) throw new Error('invalid_filter');
    }
  } catch { throw new Error('invalid_profile_avatar'); }
  return { png, color: Number(color) };
}

export function validateProfileUpdate(input: Record<string, unknown>): ProfileUpdate {
  if (!input || typeof input !== 'object' || Array.isArray(input)) throw new Error('invalid_profile_update');
  if (Object.keys(input).some(key => !['displayName','avatar'].includes(key))) throw new Error('invalid_profile_update');
  const displayName = typeof input.displayName === 'string' ? input.displayName.trim() : '';
  if (!displayName || displayName.length > 80 || /[\u0000-\u001f\u007f]/.test(displayName)) throw new Error('invalid_display_name');
  return { displayName, avatar: validateAvatar(input.avatar) };
}

export function profileRevision(): string { return randomUUID(); }
