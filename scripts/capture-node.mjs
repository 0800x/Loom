// Actual local Node server and Chromium; disposable fixture, no production writes.
import { createRequire } from 'node:module';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { LoomNodeServer } from '../services/loom_server/src/bootstrap/server.ts';
const require = createRequire(import.meta.url);
const { chromium } = require('playwright');
const folder = await mkdtemp(join(tmpdir(), 'loom-node-capture-'));
const config = {
  schemaVersion: 1, mode: 'easy', listenHost: '127.0.0.1', listenPort: 0,
  publicDomain: 'node.example.org', publicBaseUrl: 'https://node.example.org',
  dataDirectory: folder, attachmentsDirectory: join(folder, 'attachments'),
  registrationPolicy: 'approval', federationMode: 'disabled',
  networkJurisdiction: 'Fictional fixture', operatorName: 'Loom Example Node',
  adminToken: '', maxAttachmentBytes: 104857600, maxRequestBytes: 104857600,
};
delete process.env.LOOM_DONATION_LINKS;
const node = new LoomNodeServer(config);
let browser;
try {
  const bound = await node.listen();
  browser = await chromium.launch({headless: true,
    ...(process.env.LOOM_CHROMIUM ? {executablePath: process.env.LOOM_CHROMIUM} : {}),
    args: ['--no-sandbox']});
  const page = await browser.newPage({viewport: {width: 1440, height: 1100}, locale: 'en-US', reducedMotion: 'reduce'});
  await page.route('**/*', route => new URL(route.request().url()).hostname === '127.0.0.1' ? route.continue() : route.abort());
  await page.goto(`http://127.0.0.1:${bound.port}/`, {waitUntil: 'networkidle'});
  await page.screenshot({path: resolve(process.argv[2] ?? 'docs/screenshots/loom-current/node-landing-en.png'), fullPage: true});
  await writeFile(resolve(process.argv[2] ?? 'docs/screenshots/loom-current/node-landing-en.png').replace(/[^/]+$/, 'node-renderer.json'), JSON.stringify({chromium: browser.version(), node: process.version, playwright: require('playwright/package.json').version}, null, 2)+'\n');
  console.log('Captured actual Node fixture landing page with Chromium ' + browser.version());
} finally {
  if (browser) await browser.close();
  await node.close();
  await rm(folder, {recursive: true, force: true});
}
