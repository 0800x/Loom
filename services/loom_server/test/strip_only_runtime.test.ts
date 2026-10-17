import test from 'node:test';
import { readdirSync, readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

// Syntax checking alone can accept constructs rejected by the production loader.
test('all server sources support the production strip-only TypeScript mode', () => {
  const root = fileURLToPath(new URL('../src/', import.meta.url));
  function check(directory: string) {
    for (const entry of readdirSync(directory, { withFileTypes: true })) {
      const path = join(directory, entry.name);
      if (entry.isDirectory()) check(path);
      else if (entry.name.endsWith('.ts')) {
        stripTypeScriptTypes(readFileSync(path, 'utf8'), { mode: 'strip', sourceUrl: path });
      }
    }
  }
  check(root);
});

test('delivery composition imports through the production TypeScript loader', async () => {
  await import('../src/delivery/attach_v2_delivery.ts');
});
