import { BlockList, isIP } from 'node:net';
import type { IncomingMessage } from 'node:http';

function normalized(ip: string): string {
  return ip.startsWith('::ffff:') && isIP(ip.slice(7)) === 4 ? ip.slice(7) : ip;
}

/** Trust only configured proxy CIDRs, and walk forwarded hops right to left.
 * Malformed/oversized chains fall back to the TCP peer, never to a claimed IP.
 */
export class LoomClientAddressPolicy {
  private trusted = new BlockList();
  constructor(cidrs = '') {
    if (!cidrs) return;
    const entries = cidrs.split(',').map(value => value.trim());
    if (entries.length > 64) throw new Error('invalid_trusted_proxy_cidrs');
    for (const entry of entries) {
      const [ip, prefix, extra] = entry.split('/');
      const family = isIP(ip);
      const bits = Number(prefix);
      if (extra !== undefined || !family || prefix === undefined || !/^\d+$/.test(prefix) || bits < 1 || bits > (family === 4 ? 32 : 128)) throw new Error('invalid_trusted_proxy_cidrs');
      this.trusted.addSubnet(ip, bits, family === 4 ? 'ipv4' : 'ipv6');
    }
  }
  private includes(ip: string): boolean {
    const family = isIP(ip);
    return family !== 0 && this.trusted.check(ip, family === 4 ? 'ipv4' : 'ipv6');
  }
  address(request: IncomingMessage): string {
    const peer = normalized(request.socket.remoteAddress ?? 'unknown');
    if (!this.includes(peer)) return peer;
    const header = request.headers['x-forwarded-for'];
    if (typeof header !== 'string' || header.length > 2048) return peer;
    const hops = header.split(',').map(value => normalized(value.trim()));
    if (hops.length > 16 || hops.some(ip => !isIP(ip))) return peer;
    let current = peer;
    for (let i = hops.length - 1; i >= 0 && this.includes(current); i--) current = hops[i];
    return current;
  }
}
