import test from 'node:test';
import { Script } from 'node:vm';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { LoomNodeServer } from '../src/bootstrap/server.ts';
import type { LoomNodeConfig } from '../src/config/config.ts';
import { renderLandingPage, nodeStatusScript } from '../src/http/landing_page.ts';

function config(dir: string): LoomNodeConfig {
  return {
    schemaVersion: 1,
    mode: 'easy',
    listenHost: '127.0.0.1',
    listenPort: 0,
    publicDomain: 'node.example.test',
    publicBaseUrl: 'https://node.example.test',
    dataDirectory: dir,
    attachmentsDirectory: join(dir, 'attachments'),
    registrationPolicy: 'approval',
    federationMode: 'disabled',
    networkJurisdiction: 'Test',
    operatorName: 'Test Node',
    adminToken: 'test-admin-token-012345678901234567890123456789',
    maxAttachmentBytes: 1024 * 1024,
    maxRequestBytes: 1024 * 1024,
  };
}

test('public root serves the Loom landing page while API routes remain JSON', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'loom-landing-'));
  const node = new LoomNodeServer(config(dir));
  const bound = await node.listen();
  const base = `http://127.0.0.1:${bound.port}`;

  try {
    const landing = await fetch(`${base}/`);
    assert.equal(landing.status, 200);
    assert.match(landing.headers.get('content-type') ?? '', /^text\/html;/);
    assert.equal(landing.headers.get('x-frame-options'), 'DENY');
    assert.match(landing.headers.get('content-security-policy') ?? '', /default-src 'none'/);

    const body = await landing.text();
    assert.match(body, /Loom Node/);
    assert.match(body, /node\.example\.test/);
    assert.match(body, /Operator approval/);
    assert.match(body, /Federation/);
    assert.match(body, /Registered users/);
    assert.match(body, /Operational/);
    assert.match(body, /Download QR/);
    assert.match(body, /github\.com\/0800x\/Loom/);
    assert.match(body, /Public alpha/);
    assert.match(body, /Support Loom development/);
    assert.doesNotMatch(body, /t\.me\/LoomOfficial/);
    assert.equal((body.match(/href="https:\/\/t\.me\/LoomMessanger"/g) ?? []).length, 2);
    assert.doesNotMatch(body, /href="[^"]*(?:OldProjectOwner|OldProjectChannel)/i);
    assert.doesNotMatch(body, / · loom-node-v1/);
    assert.match(body, /\/assets\/loom-logo\.png/);
    assert.match(body, /--paper:#faf8f5/);
    assert.doesNotMatch(body, /--paper:#080d1b/);
    assert.match(body, /data-i18n="welcome"/);
    assert.doesNotMatch(body, /flagcdn\.com/);
    assert.equal((body.match(/class="donation-qr"/g) ?? []).length, 0);
    assert.doesNotMatch(body, /class="donation-grid"/);
    assert.match(body, /id="live-line"/);
    assert.match(body, /data-i18n="chartWaiting"/);
    assert.equal((body.match(/data-wallet-copy=/g) ?? []).length, 2);
    assert.match(body, /value="fa"/);
    assert.match(body, /value="zh"/);
    assert.match(body, /value="ru"/);
    assert.match(body, /prefers-reduced-motion/);
    assert.match(body, /prefers-color-scheme:dark/);
    assert.doesNotMatch(body, /حمایت اختیاری است|Optional USDT donations/);
    for (const [path, type] of [['loom-logo.png', 'image/png'], ['devicon-flutter.svg', 'image/svg+xml'], ['devicon-nodejs.svg', 'image/svg+xml']]) {
      const asset = await fetch(`${base}/assets/${path}`);
      assert.equal(asset.status, 200);
      assert.equal(asset.headers.get('content-type'), type);
      assert.ok((await asset.arrayBuffer()).byteLength > 100);
    }

    const statusResponse = await fetch(`${base}/api/v1/server/status`);
    const publicStatus = await statusResponse.json() as Record<string, unknown>;
    assert.equal(publicStatus.usersRegistered, 0);
    assert.equal(publicStatus.usersConnected, 0);
    assert.equal(publicStatus.status, 'operational');
    assert.equal(publicStatus.resources, undefined);
    assert.doesNotMatch(JSON.stringify(publicStatus), /adminToken|attachmentsDirectory|devices|messages|databaseUrl/);
    const qr = await fetch(`${base}/node-qr.svg`);
    assert.equal(qr.status, 200); assert.match(qr.headers.get('content-type') ?? '', /image\/svg/);
    assert.match(await qr.text(), /<svg/);
    const info = await fetch(`${base}/api/v1/server/info`);
    assert.equal(info.status, 200);
    assert.match(info.headers.get('content-type') ?? '', /^application\/json;/);
    const serverInfo = await info.json() as {domain: string; limits: {maxAttachmentBytes: number; maxMediaBytes: number}};
    assert.equal(serverInfo.domain, 'node.example.test');
    assert.equal(serverInfo.limits.maxMediaBytes, config(dir).maxAttachmentBytes - 28);
    assert.equal(serverInfo.limits.maxAttachmentBytes, config(dir).maxAttachmentBytes);
  } finally {
    await node.close();
    rmSync(dir, { recursive: true, force: true });
  }
});

test('landing page escapes operator content and does not fabricate unavailable status', () => {
  const body = renderLandingPage({ ...config('/tmp'), operatorName: '<script>alert(1)</script>', publicDomain: 'evil"<img src=x>' });
  assert.doesNotMatch(body, /<script>alert|<img src=x>/);
  assert.match(body, /&lt;script&gt;/);
  assert.match(body, /Status unavailable/);
  assert.doesNotMatch(body, />Operational</);
});

test('landing page accepts only HTTPS operator-provided donation links', () => {
  const previous = process.env.LOOM_DONATION_LINKS;
  process.env.LOOM_DONATION_LINKS = [
    'Support page|https://example.org/loom-support',
    'Unsafe|javascript:alert(1)',
    'Malformed|not-a-url',
  ].join(';');

  const dir = mkdtempSync(join(tmpdir(), 'loom-landing-render-'));
  try {
    const body = renderLandingPage(config(dir));
    assert.match(body, /Support page/);
    assert.match(body, /https:\/\/example\.org\/loom-support/);
    assert.doesNotMatch(body, /javascript:alert/);
    assert.doesNotMatch(body, />Unsafe</);
    assert.doesNotMatch(body, />Malformed</);
  } finally {
    if (previous == null) delete process.env.LOOM_DONATION_LINKS;
    else process.env.LOOM_DONATION_LINKS = previous;
    rmSync(dir, { recursive: true, force: true });
  }
});


test('resource metrics are opt-in and contain only process memory', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'loom-public-metrics-'));
  const node = new LoomNodeServer({...config(dir), publicResourceMetrics: true});
  const bound = await node.listen();
  try {
    const response = await fetch(`http://127.0.0.1:${bound.port}/api/v1/server/status`);
    const status = await response.json() as {resources: Record<string, number>};
    assert.deepEqual(Object.keys(status.resources).sort(), ['processHeapBytes','processRssBytes']);
    assert.ok(status.resources.processRssBytes > 0);
    const html = await (await fetch(`http://127.0.0.1:${bound.port}/`)).text();
    assert.match(html, /Process resources/); assert.doesNotMatch(html, /adminToken|databaseUrl|attachmentsDirectory/);
  } finally { await node.close(); rmSync(dir,{recursive:true,force:true}); }
});

test('every translated element has a translation in all four languages', () => {
  assert.doesNotThrow(() => new Script(nodeStatusScript));
  const marker = nodeStatusScript.match(/const translations = (\{[^\n]+\});/);
  assert.ok(marker, 'localization dictionary must be embedded in the self-hosted script');
  const dictionary = JSON.parse(marker[1]) as Record<string, Record<string, string>>;
  assert.deepEqual(Object.keys(dictionary).sort(), ['en','fa','ru','zh']);
  const page = renderLandingPage(config('/tmp'), {status:'operational',usersRegistered:2,usersConnected:1,uptimeSeconds:120,sampledAt:'2026-10-08T16:00:00.000Z',resources:{processRssBytes:1000000,processHeapBytes:500000}}, 'https://node.example.test', {nodeId:'test',fingerprint:'test'});
  const used = [...page.matchAll(/data-i18n="([a-zA-Z]+)"/g), ...page.matchAll(/data-i18n-(?:aria|alt)="([a-zA-Z]+)"/g)].map(m => m[1]);
  for (const lang of ['en','fa','zh','ru']) for (const key of used) {
    assert.ok(dictionary[lang][key], 'missing '+lang+' translation for '+key);
  }
  assert.match(nodeStatusScript, /\/api\/v1\/server\/status/);
  assert.match(nodeStatusScript, /appendSample/);
  assert.match(nodeStatusScript, /document\.documentElement\.dir/);
});

test('status controller switches RTL and retains counts during an outage (DOM mock)', async () => {
  const {createContext, runInContext} = await import('node:vm');
  const elements = new Map<string, any>();
  for (const id of ['language','sample','status','registered','connected','uptime','live-line','live-dot','chart-empty','chart-max','chart-now']) {
    elements.set(id, {dataset: id === 'status' ? {state:'unknown'} : {}, textContent:'', setAttribute() {}, addEventListener() {}});
  }
  let fail = false;
  const document = {hidden:true, documentElement:{lang:'',dir:''}, getElementById:(id:string)=>elements.get(id), querySelectorAll:()=>[], addEventListener() {}};
  const context = createContext({document, navigator:{language:'en'}, localStorage:{getItem:()=>'',setItem() {}}, setInterval() {}, setTimeout() {}, AbortSignal,
    fetch:async () => {if(fail) throw Error('offline'); return {ok:true,json:async()=>({status:'operational',usersRegistered:9,usersConnected:3,uptimeSeconds:120,sampledAt:'2026-10-14T12:00:00Z'})};}});
  runInContext(nodeStatusScript, context);
  runInContext("applyLanguage('fa')", context);
  assert.equal(document.documentElement.dir, 'rtl');
  document.hidden = false;
  await runInContext('refresh()', context);
  assert.equal(elements.get('connected').textContent, 3);
  assert.equal(elements.get('status').dataset.state, 'operational');
  fail = true;
  await runInContext('refresh()', context);
  assert.equal(elements.get('status').dataset.state, 'stale');
  assert.equal(elements.get('connected').textContent, 3);
  runInContext("applyLanguage('en')", context);
  assert.equal(document.documentElement.dir, 'ltr');
  assert.doesNotMatch(nodeStatusScript, /flagcdn|flagCodes|flagNames/);
});
