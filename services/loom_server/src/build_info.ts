import { readFileSync } from 'node:fs';

// Written into the image at build time. Runtime .env values must not make an
// old image claim to be the revision that the operator just requested.
export function readBuildCommit(path = new URL('../.loom-build-commit', import.meta.url)): string | null {
  try {
    const value = readFileSync(path, 'utf8').trim();
    return /^[0-9a-f]{40}$/i.test(value) ? value.toLowerCase() : null;
  } catch {
    return null;
  }
}

export const runningBuildCommit = readBuildCommit();


export const serverVersion = '0.10.10';
