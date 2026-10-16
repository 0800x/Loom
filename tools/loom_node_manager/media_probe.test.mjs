import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {createServer} from 'node:http';
import {createHmac} from 'node:crypto';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {fileURLToPath} from 'node:url';
const run = promisify(execFile);
const source = readFileSync(new URL('./media_probe.go', import.meta.url), 'utf8');
const code = source.split('const groupMediaProbe = `')[1].split('`')[0];
const cwd = fileURLToPath(new URL('../../services/loom_server/', import.meta.url));
const key = 'probe-test-key', secret = 'probe-test-secret-12345678901234567890';
async function probe(url) {
  try { return await run(process.execPath, ['--input-type=module', '-e', code], {
    cwd, env: {...process.env, LOOM_GROUP_CALLS_API_URL: url,
      LOOM_GROUP_CALLS_API_KEY: key, LOOM_GROUP_CALLS_API_SECRET: secret}, timeout: 15000,
  }); } catch (e) { return e; }
}
async function server(fn, work) {
  const s = createServer(fn); await new Promise(resolve => s.listen(0, '127.0.0.1', resolve));
  try { await work(`http://127.0.0.1:${s.address().port}`); }
  finally { s.closeAllConnections(); await new Promise(resolve => s.close(resolve)); }
}
test('probe authenticates the private room-list API using a real SDK JWT', async () => {
  let authenticated = false;
  await server((req, res) => {
    assert.equal(req.url, '/twirp/livekit.RoomService/ListRooms');
    const [header, payload, signature] = req.headers.authorization.slice(7).split('.');
    assert.equal(signature, createHmac('sha256', secret).update(`${header}.${payload}`).digest('base64url'));
    const claims = JSON.parse(Buffer.from(payload, 'base64url'));
    assert.equal(claims.iss, key); assert.equal(claims.video.roomList, true);
    authenticated = true; res.setHeader('content-type', 'application/json'); res.end('{"rooms":[]}');
  }, async url => { const result = await probe(url); assert.equal(result.code, undefined); assert.equal(result.stdout, ''); });
  assert.equal(authenticated, true);
});
test('probe reports rejected credentials without printing SDK error bodies', async () => {
  await server((_, res) => { res.writeHead(401, {'content-type':'application/json'});
    res.end(JSON.stringify({code:'unauthenticated', message: secret}));
  }, async url => { const result = await probe(url); assert.equal(result.code, 1);
    assert.equal(result.stdout.trim(), 'LOOM_MEDIA_AUTH'); assert.ok(!result.stderr.includes(secret)); });
});
test('probe retries transient startup errors and then succeeds', async () => {
  let attempts = 0;
  await server((_, res) => { attempts++; res.setHeader('content-type','application/json');
    if (attempts < 3) { res.statusCode = 503; res.end('{"code":"unavailable","message":"starting"}'); }
    else res.end('{"rooms":[]}');
  }, async url => { const result = await probe(url); assert.equal(result.code, undefined); });
  assert.equal(attempts, 3);
});
