import { mkdir, readdir, readFile, rm, stat, writeFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import type { ServerResponse } from 'node:http';

const TILE_CACHE_TTL_MS = 7 * 24 * 60 * 60 * 1000;

export interface LoomTileCacheOptions {
  /** XYZ template of the upstream raster basemap, e.g.
   * `https://tile.openstreetmap.org/{z}/{x}/{y}.png`. */
  upstreamTemplate: string;
  /** Directory that stores the cached tiles. */
  directory: string;
  maxTileBytes?: number;
  minZoom?: number;
  maxZoom?: number;
  fetchTimeoutMs?: number;
  warmConcurrency?: number;
  warmDelayMs?: number;
  /** Explicit operator opt-in for providers whose terms permit bulk prefetch. */
  allowPrefetch?: boolean;
}

export interface TileWarmJob {
  country: string | null;
  bounds: [number, number, number, number];
  minZoom: number;
  maxZoom: number;
  total: number;
  done: number;
  failed: number;
  startedAt: string;
  running: boolean;
}

/** Web-Mercator tile ranges covering a lat/lon bounding box. */
export function tileRanges(
  bounds: [number, number, number, number],
  minZoom: number,
  maxZoom: number,
): Array<{ z: number; x0: number; x1: number; y0: number; y1: number }> {
  const [west, south, east, north] = bounds;
  const ranges: Array<{ z: number; x0: number; x1: number; y0: number; y1: number }> = [];
  for (let z = minZoom; z <= maxZoom; z++) {
    const n = 2 ** z;
    const clamp = (v: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, v));
    const tileY = (latitude: number) =>
      Math.floor(
        (1 - Math.log(Math.tan((latitude * Math.PI) / 180) + 1 / Math.cos((latitude * Math.PI) / 180)) / Math.PI) / 2 * n,
      );
    ranges.push({
      z,
      x0: clamp(Math.floor(((west + 180) / 360) * n), 0, n - 1),
      x1: clamp(Math.floor(((east + 180) / 360) * n), 0, n - 1),
      // XYZ rows increase southward: north is the first row, south the last.
      y0: clamp(tileY(north), 0, n - 1),
      y1: clamp(tileY(south), 0, n - 1),
    });
  }
  return ranges;
}

export function totalTiles(ranges: Array<{ z: number; x0: number; x1: number; y0: number; y1: number }>): number {
  return ranges.reduce((sum, r) => sum + (r.x1 - r.x0 + 1) * (r.y1 - r.y0 + 1), 0);
}

/** Country code (ISO-3166 alpha-2, lowercase) → [west, south, east, north]. */
const COUNTRY_BOUNDS: Record<string, [number, number, number, number]> = {
  ir: [44.0, 25.0, 63.5, 39.8],
  iq: [38.8, 29.0, 48.6, 37.4],
  tr: [26.0, 35.8, 45.0, 42.1],
  az: [44.7, 38.4, 50.6, 41.6],
  am: [43.4, 38.8, 46.6, 41.3],
  ge: [39.9, 41.0, 46.7, 43.6],
  tm: [52.3, 35.1, 66.7, 42.8],
  af: [60.5, 29.4, 75.0, 38.5],
  pk: [60.9, 23.7, 77.0, 37.1],
  ae: [51.5, 22.5, 56.6, 26.5],
  sa: [34.5, 16.0, 56.0, 32.2],
  om: [52.0, 16.6, 60.0, 26.5],
  kw: [46.5, 28.5, 48.5, 30.1],
  qa: [50.7, 24.5, 52.5, 26.2],
  bh: [50.3, 25.7, 50.9, 26.4],
  jo: [34.9, 29.1, 39.3, 33.4],
  lb: [35.1, 33.0, 36.6, 34.7],
  sy: [35.6, 32.0, 42.4, 37.3],
  il: [34.2, 29.5, 35.9, 33.3],
  ps: [34.2, 31.2, 35.6, 32.6],
  ye: [42.5, 12.1, 54.6, 19.0],
  eg: [24.7, 21.7, 37.1, 31.7],
  de: [5.9, 47.3, 15.0, 55.1],
  fr: [-5.2, 41.3, 9.6, 51.1],
  gb: [-8.2, 49.9, 1.8, 60.9],
  nl: [3.3, 50.7, 7.2, 53.6],
  be: [2.5, 49.4, 6.4, 51.5],
  ch: [5.9, 45.8, 10.5, 47.8],
  at: [9.5, 46.4, 17.2, 49.0],
  it: [6.6, 35.5, 18.5, 47.1],
  es: [-9.4, 35.9, 3.4, 43.8],
  pt: [-9.6, 36.9, -6.2, 42.2],
  se: [11.1, 55.3, 24.2, 69.1],
  no: [4.6, 57.9, 31.2, 71.2],
  fi: [20.5, 59.8, 31.6, 70.1],
  dk: [8.0, 54.6, 13.0, 57.8],
  pl: [14.1, 49.0, 24.2, 54.9],
  cz: [12.1, 48.5, 18.9, 51.1],
  ro: [20.3, 43.6, 29.7, 48.3],
  gr: [19.4, 34.9, 28.3, 41.8],
  ru: [19.6, 41.1, 180.0, 81.9],
  ua: [22.1, 44.4, 40.2, 52.4],
  us: [-179.1, 18.0, -66.9, 71.6],
  ca: [-141.0, 41.7, -52.6, 83.1],
  mx: [-118.4, 14.5, -86.7, 32.7],
  br: [-73.9, -33.9, -34.8, 5.4],
  ar: [-73.6, -55.0, -53.6, -21.8],
  cn: [73.5, 18.1, 135.1, 53.6],
  jp: [122.9, 20.4, 154.0, 45.6],
  kr: [126.1, 33.1, 130.9, 38.6],
  in: [68.1, 6.5, 97.4, 35.7],
  id: [95.0, -11.0, 141.0, 6.0],
  au: [112.9, -43.7, 153.7, -10.7],
  nz: [166.4, -47.3, 178.5, -34.4],
  za: [16.5, -34.8, 32.9, -22.1],
  ng: [2.7, 4.2, 14.7, 13.9],
  ke: [33.9, -4.7, 41.9, 5.0],
};

export function countryBounds(code: string): [number, number, number, number] | null {
  return COUNTRY_BOUNDS[code.toLowerCase()] ?? null;
}

export function supportedCountries(): string[] {
  return Object.keys(COUNTRY_BOUNDS).sort();
}

function sniffImageType(bytes: Uint8Array): string | null {
  if (bytes.length >= 8 && bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47) return 'image/png';
  if (bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) return 'image/jpeg';
  if (bytes.length >= 12 && bytes[0] === 0x52 && bytes[1] === 0x49 && bytes[2] === 0x46 && bytes[3] === 0x46 && bytes[8] === 0x57 && bytes[9] === 0x45 && bytes[10] === 0x42 && bytes[11] === 0x50) return 'image/webp';
  return null;
}

/** Optional, OSM-compatible XYZ tile cache with country-scoped warm-up.
 *
 * Serves `GET /tiles/{z}/{x}/{y}` straight from disk when possible and
 * fetches misses from the configured upstream template. Only raster
 * basemaps are supported — never satellite imagery — and the operator is
 * responsible for choosing an upstream whose terms allow caching: the
 * OpenStreetMap tile usage policy permits low-volume proxies like this,
 * while Google's terms do not and must not be configured.
 */
export class LoomTileCacheService {
  private readonly upstreamTemplate: string;
  private readonly directory: string;
  private readonly maxTileBytes: number;
  private readonly minZoom: number;
  private readonly maxZoom: number;
  private readonly fetchTimeoutMs: number;
  private readonly warmConcurrency: number;
  private readonly warmDelayMs: number;
  private readonly allowPrefetch: boolean;
  private job: TileWarmJob | null = null;
  private bytesCached = 0;

  constructor(options: LoomTileCacheOptions) {
    if (!/^https?:\/\/.+/.test(options.upstreamTemplate) ||
        !options.upstreamTemplate.includes('{z}') ||
        !options.upstreamTemplate.includes('{x}') ||
        !options.upstreamTemplate.includes('{y}')) {
      throw new Error('invalid_tile_upstream_template');
    }
    this.upstreamTemplate = options.upstreamTemplate;
    const upstreamHost = new URL(options.upstreamTemplate.replaceAll('{z}', '0').replaceAll('{x}', '0').replaceAll('{y}', '0')).hostname.toLowerCase();
    if (upstreamHost === 'google.com' || upstreamHost.endsWith('.google.com') ||
        upstreamHost === 'googleapis.com' || upstreamHost.endsWith('.googleapis.com')) {
      throw new Error('tile_provider_caching_not_permitted');
    }
    this.directory = resolve(options.directory);
    this.maxTileBytes = options.maxTileBytes ?? 1_048_576;
    this.minZoom = options.minZoom ?? 0;
    this.maxZoom = options.maxZoom ?? 17;
    this.fetchTimeoutMs = options.fetchTimeoutMs ?? 15_000;
    this.warmConcurrency = options.warmConcurrency ?? 2;
    this.warmDelayMs = options.warmDelayMs ?? 40;
    this.allowPrefetch = options.allowPrefetch === true;
  }

  /** Bulk prefetch is opt-in and forbidden for providers whose published terms prohibit it. */
  prefetchEnabled(): boolean {
    if (!this.allowPrefetch) return false;
    let host: string;
    try {
      host = new URL(this.upstreamTemplate.replaceAll('{z}', '0').replaceAll('{x}', '0').replaceAll('{y}', '0')).hostname.toLowerCase();
    } catch {
      return false;
    }
    if (host === 'tile.openstreetmap.org' || host.endsWith('.tile.openstreetmap.org') ||
        host === 'google.com' || host.endsWith('.google.com') ||
        host === 'googleapis.com' || host.endsWith('.googleapis.com')) return false;
    return true;
  }

  validTile(z: number, x: number, y: number): boolean {
    return Number.isSafeInteger(z) && Number.isSafeInteger(x) && Number.isSafeInteger(y) &&
      z >= this.minZoom && z <= this.maxZoom && x >= 0 && y >= 0 && x < 2 ** z && y < 2 ** z;
  }

  private path(z: number, x: number, y: number): string {
    return join(this.directory, String(z), String(x), `${y}.tile`);
  }

  /** Serves a tile from cache, fetching it from upstream on a miss. Returns
   * false when the coordinates are invalid (the caller answers 404). */
  async serve(z: number, x: number, y: number, response: ServerResponse): Promise<boolean> {
    if (!this.validTile(z, x, y)) return false;
    const file = this.path(z, x, y);
    let info;
    try { info = await stat(file); } catch { info = null; }
    if (info != null && info.isFile() && Date.now() - info.mtimeMs <= TILE_CACHE_TTL_MS) {
      try {
        const cached = await readFile(file);
        const type = cached.byteLength <= this.maxTileBytes ? sniffImageType(cached) : null;
        if (type != null) {
          response.writeHead(200, {
            'content-type': type,
            'content-length': String(cached.byteLength),
            'cache-control': 'public, max-age=604800',
            'x-content-type-options': 'nosniff',
            'x-loom-tile': 'hit',
          });
          response.end(cached);
          return true;
        }
        await rm(file, { force: true });
      } catch {
        await rm(file, { force: true }).catch(() => undefined);
      }
    } else if (info != null && info.isFile()) {
      // Upstream cache headers are not persisted by this cache; use the
      // provider policy's seven-day fallback rather than retaining tiles forever.
      await rm(file, { force: true }).catch(() => undefined);
    }
    const fetched = await this.fetch(z, x, y);
    if (fetched == null) return false;
    this.bytesCached += fetched.bytes.byteLength;
    await mkdir(dirname(file), { recursive: true });
    await writeFile(file, fetched.bytes);
    response.writeHead(200, {
      'content-type': fetched.type,
      'content-length': String(fetched.bytes.byteLength),
      'cache-control': 'public, max-age=604800',
      'x-content-type-options': 'nosniff',
      'x-loom-tile': 'miss',
    });
    response.end(fetched.bytes);
    return true;
  }

  private async fetch(z: number, x: number, y: number): Promise<{ bytes: Uint8Array; type: string } | null> {
    const url = this.upstreamTemplate.replaceAll('{z}', String(z)).replaceAll('{x}', String(x)).replaceAll('{y}', String(y));
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.fetchTimeoutMs);
    try {
      const upstream = await fetch(url, {
        signal: controller.signal,
        redirect: 'error',
        headers: { 'user-agent': 'Loom-Home-Node/0.6.0 (+https://github.com/0800x/Loom)' },
      });
      if (!upstream.ok) return null;
      const buffer = new Uint8Array(await upstream.arrayBuffer());
      if (buffer.byteLength === 0 || buffer.byteLength > this.maxTileBytes) return null;
      const type = sniffImageType(buffer);
      if (type == null) return null;
      return { bytes: buffer, type };
    } catch {
      return null;
    } finally {
      clearTimeout(timer);
    }
  }

  /** Starts (or replaces) a background warm-up job for a bounding box. */
  async warm(bounds: [number, number, number, number], minZoom: number, maxZoom: number, country: string | null): Promise<TileWarmJob> {
    if (!this.prefetchEnabled()) throw new Error('tile_prefetch_disabled_for_provider');
    const clampedMin = Math.max(this.minZoom, minZoom);
    const clampedMax = Math.min(this.maxZoom, maxZoom);
    if (clampedMin > clampedMax) throw new Error('invalid_zoom_range');
    const ranges = tileRanges(bounds, clampedMin, clampedMax);
    const total = totalTiles(ranges);
    // Bound both queue memory and upstream load even for a malicious or
    // accidental world-scale request from an authenticated operator.
    if (!Number.isSafeInteger(total) || total > 50_000) throw new Error('tile_warmup_limit_exceeded');
    const job: TileWarmJob = {
      country,
      bounds,
      minZoom: clampedMin,
      maxZoom: clampedMax,
      total,
      done: 0,
      failed: 0,
      startedAt: new Date().toISOString(),
      running: true,
    };
    this.job = job;
    void this.runWarm(job, ranges);
    return { ...job };
  }

  private async runWarm(job: TileWarmJob, ranges: Array<{ z: number; x0: number; x1: number; y0: number; y1: number }>): Promise<void> {
    const queue: Array<[number, number, number]> = [];
    for (const range of ranges) {
      for (let x = range.x0; x <= range.x1; x++) {
        for (let y = range.y0; y <= range.y1; y++) queue.push([range.z, x, y]);
      }
    }
    let cursor = 0;
    const worker = async (): Promise<void> => {
      while (cursor < queue.length && this.job === job) {
        const [z, x, y] = queue[cursor++];
        const file = this.path(z, x, y);
        try {
          const info = await stat(file);
          if (info.isFile() && Date.now() - info.mtimeMs <= TILE_CACHE_TTL_MS) {
            job.done++;
            continue;
          }
          if (info.isFile()) await rm(file, { force: true });
        } catch { /* not cached yet */ }
        const fetched = await this.fetch(z, x, y);
        // A newer warm-up or purge may have replaced this job while the
        // upstream request was in flight; never repopulate a cancelled cache.
        if (this.job !== job) return;
        if (fetched == null) {
          job.failed++;
        } else {
          this.bytesCached += fetched.bytes.byteLength;
          await mkdir(dirname(file), { recursive: true });
          await writeFile(file, fetched.bytes);
          job.done++;
        }
        if (this.warmDelayMs > 0) await new Promise((pause) => setTimeout(pause, this.warmDelayMs));
      }
    };
    try {
      await Promise.all(Array.from({ length: Math.max(1, this.warmConcurrency) }, worker));
    } catch (error) {
      console.error('[loom-node] tile warm-up failed:', error);
    }
    job.running = false;
  }

  status(): Record<string, unknown> {
    return {
      job: this.job ? { ...this.job } : null,
      bytesCached: this.bytesCached,
      directory: this.directory,
      upstream: this.upstreamTemplate,
      prefetchEnabled: this.prefetchEnabled(),
      minZoom: this.minZoom,
      maxZoom: this.maxZoom,
    };
  }

  async purge(): Promise<void> {
    if (this.job) this.job.running = false;
    this.job = null;
    await rm(this.directory, { recursive: true, force: true });
    this.bytesCached = 0;
  }

  /** Best-effort disk usage scan. */
  async diskUsage(): Promise<{ files: number; bytes: number }> {
    let files = 0, bytes = 0;
    const walk = async (directory: string): Promise<void> => {
      let entries;
      try { entries = await readdir(directory, { withFileTypes: true }); } catch { return; }
      for (const entry of entries) {
        const full = join(directory, entry.name);
        if (entry.isDirectory()) await walk(full);
        else if (entry.isFile()) {
          files++;
          try { bytes += (await stat(full)).size; } catch { /* raced */ }
        }
      }
    };
    await walk(this.directory);
    return { files, bytes };
  }
}

/** Parse a `/tiles/{z}/{x}/{y}(.png)` request path. */
export function parseTilePath(pathname: string): [number, number, number] | null {
  const match = /^\/tiles\/(\d{1,2})\/(\d{1,9})\/(\d{1,9})(?:\.png)?$/.exec(pathname);
  if (!match) return null;
  return [Number(match[1]), Number(match[2]), Number(match[3])];
}
