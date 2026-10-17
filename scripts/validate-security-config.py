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
print('Production security configuration checks passed')
