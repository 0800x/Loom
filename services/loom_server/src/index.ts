import { loadOrCreateConfig } from './config/config.ts';
import { LoomNodeServer } from './bootstrap/server.ts';
import { attachV2DeliveryService } from './delivery/attach_v2_delivery.ts';

const loaded = loadOrCreateConfig();
if (loaded.created) {
  console.log(`[loom-node] created configuration: ${loaded.path}`);
  console.log('[loom-node] IMPORTANT: save the generated admin token securely and review registration/federation policy before Internet exposure.');
}
const server = await LoomNodeServer.create(loaded.config);
await attachV2DeliveryService(server, loaded.config);
let address: { host: string; port: number };
try {
  address = await server.listen();
} catch (error) {
  const code = error && typeof error === 'object' && 'code' in error ? String(error.code) : '';
  if (code === 'EADDRINUSE') {
    console.error(`[loom-node] cannot start: port ${loaded.config.listenPort} is already in use on ${loaded.config.listenHost}`);
    console.error('[loom-node] another Loom Node may already be running; check /healthz before stopping any process');
    process.exit(1);
  }
  throw error;
}
console.log(`[loom-node] ${loaded.config.mode} mode listening on ${address.host}:${address.port}`);
console.log(`[loom-node] public identity: ${server.config.publicDomain}`);

let closing = false;
async function shutdown(signal: string): Promise<void> {
  if (closing) return;
  closing = true;
  console.log(`[loom-node] ${signal}; shutting down`);
  try { await server.close(); process.exitCode = 0; } catch (error) { console.error(error); process.exitCode = 1; }
}
process.on('SIGINT', () => void shutdown('SIGINT'));
process.on('SIGTERM', () => void shutdown('SIGTERM'));
