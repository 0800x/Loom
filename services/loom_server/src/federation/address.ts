import { isIP } from 'node:net';
import { domainToASCII } from 'node:url';

export interface LoomAddress {
  username: string;
  domain: string;
  canonical: string;
  isLocal: boolean;
}

const USERNAME_RE = /^[a-z0-9_][a-z0-9_.-]{2,31}$/;
const LABEL_RE = /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/;

/// Loom calls this a domain in federation contracts, but local/LAN Home
/// Nodes may include an explicit port. Normalize it as an authority while
/// still rejecting URL paths, credentials, queries, and malformed hosts.
export function normalizeLoomDomain(value: string): string {
  const raw = value.trim().toLowerCase();
  if (!raw ||
      raw.length > 320 ||
      /\s/.test(raw) ||
      raw.includes('/') ||
      raw.includes('\\') ||
      raw.includes('@') ||
      raw.includes('?') ||
      raw.includes('#')) {
    throw new Error('invalid_loom_domain');
  }

  let parsed: URL;
  try { parsed = new URL(`https://${raw}`); } catch { throw new Error('invalid_loom_domain'); }
  if (!parsed.hostname || parsed.username || parsed.password || parsed.pathname !== '/' || parsed.search || parsed.hash) {
    throw new Error('invalid_loom_domain');
  }

  let hostname = parsed.hostname.toLowerCase().replace(/\.$/, '');
  if (hostname.startsWith('[') && hostname.endsWith(']')) {
    const inner = hostname.slice(1, -1);
    if (isIP(inner) !== 6) throw new Error('invalid_loom_domain');
    hostname = `[${inner}]`;
  } else {
    let ascii: string;
    try { ascii = domainToASCII(hostname).toLowerCase(); } catch { throw new Error('invalid_loom_domain'); }
    if (!ascii || ascii.length > 253) throw new Error('invalid_loom_domain');
    if (isIP(ascii) === 0 && ascii.split('.').some((label) => !LABEL_RE.test(label))) {
      throw new Error('invalid_loom_domain');
    }
    hostname = ascii;
  }

  const authority = parsed.port ? `${hostname}:${parsed.port}` : hostname;
  if (authority.length > 320) throw new Error('invalid_loom_domain');
  return authority;
}

export function normalizeLoomUsername(value: string): string {
  const username = value.trim().toLowerCase();
  if (!USERNAME_RE.test(username)) throw new Error('invalid_loom_username');
  return username;
}

export function formatLoomAddress(username: string, domain: string): string {
  return `@${normalizeLoomUsername(username)}:${normalizeLoomDomain(domain)}`;
}

export function parseLoomAddress(value: string, localDomain?: string): LoomAddress {
  const input = value.trim();
  if (input.length < 6 || input.length > 360 || !input.startsWith('@')) {
    throw new Error('invalid_loom_address');
  }
  // The first colon separates username from Home Node. The Home Node itself
  // may contain a port (or bracketed IPv6), so later colons are valid.
  const separator = input.indexOf(':', 1);
  if (separator <= 1 || separator === input.length - 1) {
    throw new Error('invalid_loom_address');
  }
  const username = normalizeLoomUsername(input.slice(1, separator));
  const domain = normalizeLoomDomain(input.slice(separator + 1));
  const normalizedLocal = localDomain == null ? null : normalizeLoomDomain(localDomain);
  return {
    username,
    domain,
    canonical: `@${username}:${domain}`,
    isLocal: normalizedLocal === domain,
  };
}

export function isLoomAddress(value: string): boolean {
  try { parseLoomAddress(value); return true; } catch { return false; }
}
