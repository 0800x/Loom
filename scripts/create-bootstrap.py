#!/usr/bin/env python3
"""Create the versioned, integrity-pinned first-install bootstrap and Node channel."""
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
output = Path(sys.argv[1]).resolve()
output.mkdir(parents=True, exist_ok=True)
revision = subprocess.check_output(["git", "-C", str(ROOT), "rev-parse", "HEAD"], text=True).strip()
if not re.fullmatch(r"[0-9a-f]{40}", revision):
    raise SystemExit("Invalid release revision")
archive = subprocess.check_output(["git", "-C", str(ROOT), "archive", "--format=tar", revision])
archive_sha = hashlib.sha256(archive).hexdigest()
bootstrap_sha = hashlib.sha256((ROOT / "scripts/install-loom-node.sh").read_bytes()).hexdigest()
template = (ROOT / "install.sh").read_text(encoding="utf-8")
pins = {
    "LOOM_INSTALL_REVISION": revision,
    "LOOM_INSTALL_ARCHIVE_SHA256": archive_sha,
    "LOOM_INSTALL_BOOTSTRAP_SHA256": bootstrap_sha,
}
for name, value in pins.items():
    template, count = re.subn(rf"(?m)^{name}='[0-9a-f]+'$", f"{name}='{value}'", template)
    if count != 1:
        raise SystemExit(f"Expected exactly one {name} pin in install.sh")
installer = output / "loom-install.sh"
installer.write_text(template, encoding="utf-8")
installer.chmod(0o755)
installer_sha = hashlib.sha256(installer.read_bytes()).hexdigest()
(output / "loom-install.sh.sha256").write_text(f"{installer_sha}  loom-install.sh\n", encoding="utf-8")
previous = json.loads((ROOT / "release/node-channel.json").read_text(encoding="utf-8"))
channel = {
    "schema": 1,
    "repository": "0800x/Loom",
    "branch": "main",
    "revision": revision,
    "sha256": archive_sha,
    "sequence": int(previous["sequence"]) + 1,
}
(output / "node-channel.json").write_text(json.dumps(channel, indent=2) + "\n", encoding="utf-8")
sys.path.insert(0, str(ROOT / "scripts"))
import release  # noqa: E402
release.checksums(output)
print(f"Prepared bootstrap and publisher channel for {revision}")
