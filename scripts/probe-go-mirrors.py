#!/usr/bin/env python3
"""Read-only public Go mirror diagnostics; not a cryptographic acceptance test."""
import concurrent.futures
import json
from pathlib import Path
import subprocess
import tempfile
import zipfile

MIRRORS = {
    'liara': 'https://package-mirror.liara.ir/repository/go',
    'runflare': 'https://mirror-go.runflare.com',
    'goproxy-cn': 'https://goproxy.cn',
    'official': 'https://proxy.golang.org',
}
MODULE = '/github.com/zeebo/errs/@v/v1.4.0.zip'


def probe(item):
    name, base = item
    with tempfile.TemporaryDirectory(prefix='loom-mirror-probe-') as temp:
        payload = Path(temp) / 'module.zip'
        result = subprocess.run([
            'curl', '--proto', '=https', '--proto-redir', '=https', '--tlsv1.2',
            '--location', '--silent', '--show-error', '--connect-timeout', '5',
            '--max-time', '20', '--max-filesize', '2097152', '--output', str(payload),
            '--write-out', '%{http_code} %{size_download} %{time_total}', base + MODULE,
        ], capture_output=True, text=True, timeout=25)
        fields = result.stdout.split()
        return {
            'mirror': name, 'baseURL': base, 'curlExitCode': result.returncode,
            'httpStatus': fields[0] if fields else '000',
            'bytes': fields[1] if len(fields) > 1 else '0',
            'seconds': fields[2] if len(fields) > 2 else None,
            'zipReceived': result.returncode == 0 and fields[0] == '200' and zipfile.is_zipfile(payload),
        }


if __name__ == '__main__':
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        results = list(pool.map(probe, MIRRORS.items()))
    print(json.dumps({
        'scope': 'small public module ZIP from this runner; not Iran-server reachability or checksum verification',
        'results': results,
    }, indent=2))
