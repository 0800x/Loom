import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, statSync, rmSync, copyFileSync, chmodSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { spawn, spawnSync } from 'node:child_process';
import { once } from 'node:events';
import { readBuildCommit } from '../src/build_info.ts';

const metadata = fileURLToPath(new URL('../scripts/linux/update-metadata.sh', import.meta.url));
const linuxOnly = {skip:process.platform!=='linux'};

test('manual update replaces stale env channel while preserving secrets, permissions and unrelated configuration', linuxOnly, () => {
  const dir=mkdtempSync(join(tmpdir(),'loom-update-channel-'));
  mkdirSync(join(dir,'deploy'));
  const envPath=join(dir,'deploy','.env');
  const preserved='# retained configuration\nLOOM_ADMIN_TOKEN=secret-with-$-and-\\\nPOSTGRES_PASSWORD=keep=all=equals\nLOOM_TURN_SHARED_SECRET=unchanged\nLOOM_AUTO_UPDATE=false\n';
  writeFileSync(envPath,preserved+'LOOM_UPDATE_BRANCH=main\n  LOOM_UPDATE_BRANCH =release/old\nLOOM_UPDATE_REPOSITORY=old/repository\n',{mode:0o600});
  const before=statSync(envPath);
  try {
    const result=spawnSync('bash',['-c','set -euo pipefail; source "$1"; loom_write_update_channel "$2" 0800x/Loom main /opt/loom-src','test',metadata,dir],{encoding:'utf8'});
    assert.equal(result.status,0,result.stderr);
    const current=readFileSync(envPath,'utf8');
    assert.ok(current.startsWith(preserved));
    assert.match(current,/^LOOM_UPDATE_BRANCH=main$/m);
    assert.equal(current.match(/^LOOM_UPDATE_BRANCH=/gm)?.length,1);
    assert.doesNotMatch(current,/release\/old/);
    assert.match(current,/^LOOM_UPDATE_REPOSITORY=0800x\/Loom$/m);
    assert.match(current,/^LOOM_UPDATE_SOURCE_DIR=\/opt\/loom-src$/m);
    const after=statSync(envPath);
    assert.equal(after.mode&0o777,before.mode&0o777);
    assert.equal(after.uid,before.uid);
    assert.equal(after.gid,before.gid);
  } finally {rmSync(dir,{recursive:true,force:true});}
});

test('invalid update channel leaves production env untouched', linuxOnly, () => {
  const dir=mkdtempSync(join(tmpdir(),'loom-update-channel-invalid-'));
  mkdirSync(join(dir,'deploy'));
  const envPath=join(dir,'deploy','.env');
  const original='LOOM_UPDATE_BRANCH=main\nLOOM_ADMIN_TOKEN=unchanged\n';
  writeFileSync(envPath,original,{mode:0o600});
  try {
    const result=spawnSync('bash',['-c','source "$1"; loom_write_update_channel "$2" 0800x/Loom "bad\nLOOM_ADMIN_TOKEN=overwritten" /opt/loom-src','test',metadata,dir],{encoding:'utf8'});
    assert.notEqual(result.status,0);
    assert.equal(readFileSync(envPath,'utf8'),original);
  } finally {rmSync(dir,{recursive:true,force:true});}
});


test('setup wizard exposes managed coturn automation without printing the shared secret', () => {
  const script=readFileSync(fileURLToPath(new URL('../scripts/linux/setup.sh', import.meta.url)),'utf8');
  assert.match(script,/--turn auto\|manual\|off/);
  assert.match(script,/openssl rand -hex 32/);
  assert.match(script,/static-auth-secret=\$secret/);
  assert.match(script,/LOOM_TURN_URLS "turn:\$DOMAIN:3478\?transport=udp,turn:\$DOMAIN:3478\?transport=tcp"/);
  assert.match(script,/ufw allow 49160:49200\/udp/);
  assert.match(script,/The shared secret was generated\/preserved automatically and is not printed/);
});

test('install state replaces stale commit and retains the selected architecture branch without touching secrets', linuxOnly, () => {
  const dir=mkdtempSync(join(tmpdir(),'loom-update-state-'));
  try {
    writeFileSync(join(dir,'.loom-update-state'),'installed_commit=82070ad54f\nbranch=main\n');
    writeFileSync(join(dir,'secrets'),'unchanged');
    const commit='a'.repeat(40);
    const result=spawnSync('bash',['-c','set -euo pipefail; source "$1"; loom_write_install_state "$2" 0800x/Loom main /opt/loom-src "$3" 0.7.4','test',metadata,dir,commit],{encoding:'utf8'});
    assert.equal(result.status,0,result.stderr);
    const state=readFileSync(join(dir,'.loom-update-state'),'utf8');
    assert.match(state,new RegExp(`installed_commit=${commit}`));
    assert.match(state,/branch=main/);
    assert.equal(statSync(join(dir,'.loom-update-state')).mode&0o777,0o600);
    assert.equal(readFileSync(join(dir,'secrets'),'utf8'),'unchanged');
    const bad=spawnSync('bash',['-c','source "$1"; loom_write_install_state "$2" 0800x/Loom "bad\nbranch" /opt/loom-src "$3" 0.7.4','test',metadata,dir,commit]);
    assert.notEqual(bad.status,0);
    assert.equal(readFileSync(join(dir,'.loom-update-state'),'utf8'),state);
  } finally {rmSync(dir,{recursive:true,force:true});}
});

test('replacing a running Manager executable is atomic and does not hit text-file-busy', linuxOnly, async () => {
  const dir=mkdtempSync(join(tmpdir(),'loom-update-binary-'));
  const target=join(dir,'manager'), replacement=join(dir,'replacement');
  copyFileSync('/bin/sleep',target);chmodSync(target,0o755);
  writeFileSync(replacement,'#!/bin/sh\nprintf "new-manager"\n',{mode:0o755});
  const running=spawn(target,['30']);
  await once(running,'spawn');
  try {
    const result=spawnSync('bash',['-c','set -euo pipefail; source "$1"; loom_install_manager_binary "$2" "$3"','test',metadata,replacement,target],{encoding:'utf8'});
    assert.equal(result.status,0,result.stderr);
    assert.equal(spawnSync(target,[],{encoding:'utf8'}).stdout,'new-manager');
    assert.equal(running.exitCode,null);
  } finally {const exited=once(running,'exit');running.kill();await exited;rmSync(dir,{recursive:true,force:true});}
});

test('running Node revision comes from the image file, never a mutable runtime environment claim', () => {
  const dir=mkdtempSync(join(tmpdir(),'loom-image-revision-'));
  const path=join(dir,'revision');
  const prior=process.env.LOOM_BUILD_COMMIT;
  try {
    process.env.LOOM_BUILD_COMMIT='b'.repeat(40);
    writeFileSync(path,'a'.repeat(40)+'\n');
    assert.equal(readBuildCommit(pathToFileURL(path)),'a'.repeat(40));
    writeFileSync(path,'unknown');assert.equal(readBuildCommit(pathToFileURL(path)),null);
    rmSync(path);assert.equal(readBuildCommit(pathToFileURL(path)),null);
  } finally {
    if(prior==null)delete process.env.LOOM_BUILD_COMMIT;else process.env.LOOM_BUILD_COMMIT=prior;
    rmSync(dir,{recursive:true,force:true});
  }
});
