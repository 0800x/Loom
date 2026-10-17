// SDP is a multiline protocol document, not a header or an identifier. Preserve
// CRLF/LF exactly across WebSocket, REST recovery and signed federation.
export function validCallSdp(value: unknown): value is string {
  return typeof value === 'string' && value.length > 0 &&
    Buffer.byteLength(value, 'utf8') <= 512 * 1024 &&
    !/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/.test(value);
}
