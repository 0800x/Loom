#!/usr/bin/env python3
"""CI guard for production transport/signing/privileged cleanup contracts."""
from pathlib import Path
import re
root = Path(__file__).resolve().parent.parent
manifest = (root/'apps/loom/android/app/src/main/AndroidManifest.xml').read_text()
gradle = (root/'apps/loom/android/app/build.gradle.kts').read_text()
assert 'android:usesCleartextTraffic="false"' in manifest
assert 'signingConfigs.getByName("debug")' not in gradle
assert 'signingConfigs.getByName("production")' in gradle
assert 'releaseSigning.values.all' in gradle
for path in (root/'services/loom_server/scripts/linux').glob('*.sh'):
    assert not re.search(r'\bsudo\s+-E\b',path.read_text()), path
uninstall=(root/'services/loom_server/scripts/linux/uninstall-production.sh').read_text()
assert 'IGNORECASE' not in uninstall
assert 'loom_require_install_owner' in uninstall
assert 'label=org.loom.installation=/opt/loom-node' in uninstall
# Mirrors must preserve content addressing for every production container image.
for relative in ['services/loom_server/deploy/Dockerfile', 'services/loom_server/deploy/Dockerfile.storage', 'services/loom_server/deploy/docker-compose.production.yml']:
    lines=(root/relative).read_text().splitlines()
    for index,line in enumerate(lines):
        match=re.match(r'\s*(?:FROM|image:)\s+(\S+)',line)
        if match:
            image = match[1]
            if relative.endswith('.yml') and image.startswith('ghcr.io/0800x/loom-'):
                # First-party images are addressed by the exact verified source
                # commit selected by the bootstrap, never by a floating tag.
                assert image in (
                    'ghcr.io/0800x/loom-node:${LOOM_IMAGE_TAG:?set LOOM_IMAGE_TAG}',
                    'ghcr.io/0800x/loom-minio:${LOOM_IMAGE_TAG:?set LOOM_IMAGE_TAG}',
                ), (relative, image)
                installer = (root/'services/loom_server/scripts/linux/install-production.sh').read_text()
                assert 'LOOM_IMAGE_TAG=$INSTALL_COMMIT' in installer, relative
                assert 'set_env_value "$EXISTING_ENV" LOOM_IMAGE_TAG "$INSTALL_COMMIT"' in installer, relative
            elif relative.endswith('.yml') and image.startswith(('loom-minio-source:', 'loom-node-init-source:', 'loom-node-source:')):
                assert lines[index+1].strip()=='pull_policy: build', relative
                block=[]
                for following in lines[index+1:]:
                    if re.match(r'^  [a-z][a-z-]*:',following):break
                    block.append(following)
                assert '    build:' in block, relative
            else:
                assert re.search(r'@sha256:[0-9a-f]{64}$', image), (relative, image)
print('Production security configuration checks passed')
