import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const read=(path:string)=>readFileSync(new URL('../../../'+path,import.meta.url),'utf8');
test('Android secures the window before Flutter and App Lock cannot clear capture protection',()=>{
 const main=read('apps/loom/android/app/src/main/kotlin/app/loom/messenger/MainActivity.kt');
 const lock=read('apps/loom/android/app/src/main/kotlin/app/loom/messenger/LoomAppLockBridge.kt');
 assert.match(main,/override fun onCreate[\s\S]*?FLAG_SECURE[\s\S]*?super\.onCreate/);
 assert.doesNotMatch(lock,/clearFlags\(WindowManager\.LayoutParams\.FLAG_SECURE\)/);
 assert.doesNotMatch(read('apps/loom/android/app/src/main/AndroidManifest.xml'),/android:(showWhenLocked|turnScreenOn)="true"/);
});
