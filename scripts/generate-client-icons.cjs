// Generate every native brand icon from the user-supplied Loom vectors.
// Requires sharp. Run: node scripts/generate-client-icons.cjs
const fs = require('node:fs/promises');
const path = require('node:path');
const sharp = require('sharp');
const root = path.resolve(__dirname, '..');
const output = async (file, bytes) => {
  await fs.mkdir(path.dirname(file), {recursive: true});
  await fs.writeFile(file, bytes);
};
const brand = path.join(root, 'assets/brand');

async function main() {
  const source = await fs.readFile(path.join(brand, 'loom-launcher-color.svg'), 'utf8');
  const light = await fs.readFile(path.join(brand, 'loom-light.svg'), 'utf8');
  const paths = [...source.matchAll(/<path\b[^>]*\bd="([^"]+)"[^>]*>/g)].map(m => m[1]);
  if (!paths.length || !source.includes('translate(500 500)')) {
    throw Error('Unsupported brand vector structure; refusing to fall back to an old logo');
  }
  const png = size => sharp(Buffer.from(source)).resize(size, size).removeAlpha().png().toBuffer();
  const withoutBackground = svg => svg.replace(/<rect\b[^>]*\/>/g, '');
  const compact = async svg => sharp(Buffer.from(withoutBackground(svg)))
    .trim({background: '#00000000', threshold: 1})
    .resize(512, 512, {fit: 'contain', background: '#00000000'})
    .png().toBuffer();
  const design = path.join(root, 'packages/loom_design/assets/branding');
  await output(path.join(design, 'loom_logo.png'), await compact(source));
  await output(path.join(design, 'loom_logo_light.png'), await compact(light));
  await output(path.join(design, 'loom_launcher.png'), await png(1024));
  await output(path.join(brand, 'loom-logo.png'), await png(1024));
  await output(path.join(root, 'icon.png'), await png(1024));
  await output(path.join(root, 'services/loom_server/src/http/assets/loom-logo.png'), await png(256));
  // Existing documented vector paths remain aliases of the approved new mark.
  await output(path.join(brand, 'loom-mark.svg'), source);
  await output(path.join(brand, 'loom-mark-mono.svg'), await fs.readFile(path.join(brand, 'loom-transparent.svg')));

  for (const appName of ['loom', 'loom_node_ui']) {
    const app = path.join(root, 'apps', appName);
    for (const platform of ['ios', 'macos']) {
      const target = path.join(app, platform, 'Runner/Assets.xcassets/AppIcon.appiconset');
      let manifest;
      try { manifest = JSON.parse(await fs.readFile(path.join(target, 'Contents.json'), 'utf8')); }
      catch (e) { if (e.code === 'ENOENT') continue; throw e; }
      for (const entry of manifest.images) {
        if (!entry.filename) continue;
        const size = Math.round(parseFloat(entry.size) * parseFloat(entry.scale));
        await output(path.join(target, entry.filename), await png(size));
      }
    }
    const windows = path.join(app, 'windows/runner/resources');
    try {
      await fs.access(windows);
      await output(path.join(windows, 'app_icon.ico'), await fs.readFile(path.join(brand, 'loom-windows.ico')));
    } catch (e) { if (e.code !== 'ENOENT') throw e; }
  }
  const app = path.join(root, 'apps/loom');
  const res = path.join(app, 'android/app/src/main/res');
  for (const [density, size] of Object.entries({mdpi:48, hdpi:72, xhdpi:96, xxhdpi:144, xxxhdpi:192})) {
    await output(path.join(res, 'mipmap-'+density, 'ic_launcher.png'), await png(size));
  }
  const vector = (viewport, scale, center, color) =>
    '<vector xmlns:android="http://schemas.android.com/apk/res/android" '+
    `android:width="${viewport}dp" android:height="${viewport}dp" `+
    `android:viewportWidth="${viewport}" android:viewportHeight="${viewport}">\n`+
    `<group android:scaleX="${scale}" android:scaleY="${scale}" android:translateX="${center}" android:translateY="${center}">\n`+
    paths.map(d => `<path android:pathData="${d}" android:fillColor="${color}"/>`).join('\n')+
    '\n</group>\n</vector>\n';
  await output(path.join(res, 'drawable/ic_launcher_foreground.xml'), vector(108, .108, 54, '#F4A28C'));
  await output(path.join(res, 'drawable/ic_launcher_monochrome.xml'), vector(108, .108, 54, '#FFFFFFFF'));
  await output(path.join(res, 'drawable/ic_stat_message.xml'), vector(24, .038, 12, '#FFFFFFFF'));
  const adaptive = mono =>
    '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'+
    '  <background android:drawable="@color/loom_launcher_background"/>\n'+
    '  <foreground android:drawable="@drawable/ic_launcher_foreground"/>\n'+
    (mono?'  <monochrome android:drawable="@drawable/ic_launcher_monochrome"/>\n':'')+
    '</adaptive-icon>\n';
  await output(path.join(res, 'mipmap-anydpi-v26/ic_launcher.xml'), adaptive(false));
  await output(path.join(res, 'mipmap-anydpi-v33/ic_launcher.xml'), adaptive(true));
  await output(path.join(res, 'values/launcher_colors.xml'), '<resources><color name="loom_launcher_background">#111318</color></resources>\n');
  // Native splash references the same new mark, not a legacy/default image.
  const splash = '<layer-list xmlns:android="http://schemas.android.com/apk/res/android">\n'+
    '<item android:drawable="@color/loom_launcher_background"/>\n'+
    '<item android:width="108dp" android:height="108dp" android:gravity="center" android:drawable="@drawable/ic_launcher_foreground"/>\n'+
    '</layer-list>\n';
  for (const folder of ['drawable', 'drawable-v21']) {
    await output(path.join(res, folder, 'launch_background.xml'), splash);
  }
  const launch = path.join(app, 'ios/Runner/Assets.xcassets/LaunchImage.imageset');
  for (const [name, size] of [['LaunchImage.png',168],['LaunchImage@2x.png',336],['LaunchImage@3x.png',504]]) {
    await output(path.join(launch, name), await png(size));
  }
  process.stdout.write('Generated Loom brand assets, native icons, splash and notification mark from supplied artwork.\n');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
