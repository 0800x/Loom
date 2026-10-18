import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { createDefaultConfig, validateConfig } from '../src/config/config.ts';
import { LoomRateLimiter, RateLimitError } from '../src/security/rate_limiter.ts';

const repo = fileURLToPath(new URL('../../../', import.meta.url));
const linux = { skip: process.platform !== 'linux' };
test('production rejects sample credentials for every configured purpose', () => {
  const base = { ...createDefaultConfig(), mode: 'production' as const,
    publicDomain: 'chat.example.org', publicBaseUrl: 'https://chat.example.org',
    adminToken: 'a'.repeat(40), databaseUrl: 'postgres://loom:db-independent-credential@postgres/loom',
    objectStore: { region: 'us-east-1', bucket: 'loom', accessKeyId: 'unique-access-key', secretAccessKey: 'unique-s3-credential-01234567890123456789' } };
  assert.doesNotThrow(() => validateConfig(base));
  for (const sample of ['replace-with-at-least-32-random-characters', 'replace-with-a-strong-random-password', 'minioadmin', 'changeme']) {
    assert.throws(() => validateConfig({ ...base, adminToken: sample }));
    assert.throws(() => validateConfig({ ...base, rtcTurnSharedSecret: sample }));
    assert.throws(() => validateConfig({ ...base, databaseUrl: `postgres://loom:${sample}@postgres/loom` }));
    assert.throws(() => validateConfig({ ...base, objectStore: { ...base.objectStore, secretAccessKey: sample } }));
    assert.throws(() => validateConfig({ ...base, objectStore: { ...base.objectStore, accessKeyId: sample } }));
  }
  assert.throws(() => validateConfig({ ...base, objectStore: { ...base.objectStore, secretAccessKey: base.adminToken } }), /independent/);
});

test('rate limits enforce bursts, independent scopes, refill and bounded state', () => {
  const limiter = new LoomRateLimiter(2, 1);
  limiter.consume('login', 'ip', 2, 0); limiter.consume('login', 'ip', 2, 0);
  assert.throws(() => limiter.consume('login', 'ip', 2, 0), RateLimitError);
  limiter.consume('account', 'alice', 1, 0);
  limiter.consume('account', 'bob', 1, 0);
  assert.throws(() => limiter.consume('account', 'bob', 1, 0), RateLimitError);
  limiter.consume('account', 'bob', 1, 60001);
  const release = limiter.enter(); assert.throws(() => limiter.enter(), RateLimitError);
  release(); release(); limiter.enter()();
});

test('uninstall refuses dangerous, empty, traversal and symlink roots before side effects', linux, () => {
  const script = join(repo, 'services/loom_server/scripts/linux/uninstall-production.sh');
  for (const path of ['/', '/opt', '/tmp', '', '/tmp/loom-user-controlled', '/opt/loom-node/../', '/opt/loom-node/']) {
    const result = spawnSync('/bin/bash', [script, '--yes', '--purge-all'], { env: { PATH:'/usr/bin:/bin', LOOM_NODE_HOME:path }, encoding:'utf8' });
    assert.notEqual(result.status, 0, path); assert.match(result.stderr, /unsafe|Unsafe/);
  }
});

test('installer refuses mutable revisions and missing authenticated checksum', linux, () => {
  const script = join(repo, 'scripts/install-loom-node.sh');
  for (const ref of ['main', 'main', 'a'.repeat(39), 'a'.repeat(40)+';id']) {
    const result = spawnSync('/bin/bash', [script], {env:{PATH:'/usr/bin:/bin',LOOM_REF:ref}, encoding:'utf8'});
    assert.notEqual(result.status,0); assert.match(result.stderr,/immutable/);
  }
  const result=spawnSync('/bin/bash',[script],{env:{PATH:'/usr/bin:/bin',LOOM_REF:'a'.repeat(40)},encoding:'utf8'});
  assert.notEqual(result.status,0);assert.match(result.stderr,/SHA256/);
});

// Exercise the actual function bodies and final orchestration with harmless
// doubles. No Docker/certbot/filesystem production operations are performed.
const installer = readFileSync(join(repo, 'services/loom_server/scripts/linux/install-production.sh'), 'utf8');
test('certificate failure and HTTPS failure both stop before success/state persistence', linux, () => {
  const start = installer.indexOf('if [[ $NO_START -eq 0 ]]; then\n  ui_step 6');
  assert.ok(start > 0);
  const tail = installer.slice(start);
  const preamble = `set -euo pipefail
NO_START=0; PROXY_MODE=nginx; INSTALL_COMMIT=${'a'.repeat(40)}; INSTALL_DIR=/opt/loom-node; UPDATE_REPOSITORY=0800x/Loom; UPDATE_BRANCH=main; UPDATE_SOURCE_DIR=''; MANAGER_VERSION=test; FIRST_INSTALL=0; REGISTRATION=closed; FEDERATION=disabled; DOMAIN=example.org
UI_GREEN=''; UI_BOLD=''; UI_RESET=''
ui_step(){ :; }; ui_info(){ :; }; ui_fail(){ :; }; ui_warn(){ :; }; stop_embedded_caddy_for_nginx(){ :; }; compose(){ return 0; }; launch_tui(){ :; }
loom_write_install_state(){ echo PERSISTED; }
`;
  for (const failure of ['certificate','https']) {
    const doubles = `configure_nginx_tls(){ ${failure==='certificate'?'return 1':':'}; }; verify_https(){ ${failure==='https'?'return 1':':'}; };\n`;
    const result=spawnSync('/bin/bash',['-c',preamble+doubles+tail],{encoding:'utf8',env:{PATH:'/usr/bin:/bin'}});
    assert.notEqual(result.status,0,result.stderr);assert.doesNotMatch(result.stdout,/Installation complete|Public URL|PERSISTED/);
  }
});

test('Android production stays TLS-only and release signing never falls back to debug', () => {
  const manifest=readFileSync(join(repo,'apps/loom/android/app/src/main/AndroidManifest.xml'),'utf8');
  const gradle=readFileSync(join(repo,'apps/loom/android/app/build.gradle.kts'),'utf8');
  assert.match(manifest,/android:usesCleartextTraffic="false"/);
  assert.doesNotMatch(gradle,/signingConfigs.getByName\("debug"\)/);
  assert.match(gradle,/signingConfigs.getByName\("production"\)/);
  assert.match(gradle,/releaseSigning.values.all/);
  assert.match(gradle,/androiddebugkey/);
});

test('privilege wrappers preserve no broad environment and Docker cleanup requires exact ownership', () => {
  for(const name of ['manager.sh','install-cli.sh','install-production.sh','setup.sh','uninstall-production.sh']) {
    const script=readFileSync(join(repo,'services/loom_server/scripts/linux',name),'utf8');
    assert.doesNotMatch(script,/sudo -E/);
  }
  const script=readFileSync(join(repo,'services/loom_server/scripts/linux/uninstall-production.sh'),'utf8');
  assert.doesNotMatch(script,/IGNORECASE|\/loom\/|docker image rm/);
  assert.match(script,/label=org\.loom\.installation=\/opt\/loom-node/);
  assert.match(script,/loom_require_install_owner/);
});

test('installation ownership check refuses symlink markers', linux, () => {
  const directory = mkdtempSync(join(tmpdir(),'loom-symlink-check-'));
  try {
    const result = spawnSync('/bin/bash',['-c','set -e; source "$1"; ln -s /etc/passwd "$2/marker"; loom_require_root_owned "$2/marker"','test',join(repo,'services/loom_server/scripts/linux/install-safety.sh'),directory],{encoding:'utf8',env:{PATH:'/usr/bin:/bin'}});
    assert.notEqual(result.status,0);
  } finally {rmSync(directory,{recursive:true,force:true});}
});
