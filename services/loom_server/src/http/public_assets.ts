import { readFileSync } from 'node:fs';

// Explicit allowlist. The URL can never select an arbitrary server file.
export const publicAssets = new Map([
  ['/assets/loom-logo.png', { type: 'image/png', bytes: readFileSync(new URL('./assets/loom-logo.png', import.meta.url)) }],
  ['/assets/devicon-flutter.svg', { type: 'image/svg+xml', bytes: readFileSync(new URL('./assets/devicon-flutter.svg', import.meta.url)) }],
  ['/assets/devicon-nodejs.svg', { type: 'image/svg+xml', bytes: readFileSync(new URL('./assets/devicon-nodejs.svg', import.meta.url)) }],
]);
