#!/usr/bin/env python3
"""Fail-closed alpha version, artifact, provenance and export checks (stdlib only)."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import struct
import subprocess
import tarfile
import zipfile

ROOT = Path(__file__).resolve().parent.parent

def git(*args):
    return subprocess.check_output(['git', '-C', str(ROOT), *args], text=True).strip()

def version():
    return json.loads((ROOT / 'release/version.json').read_text())

def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def validate_protocol_contract():
    contracts = json.loads((ROOT / 'release/compatibility-contract.json').read_text())
    for name, domains in contracts.items():
        source = (ROOT / name).read_text()
        for domain in domains:
            if not (domain.lower().startswith('loom') or '/loom/' in domain.lower()) or domain not in source:
                raise ValueError('Protocol namespace contract mismatch: ' + name)

def preflight():
    validate_protocol_contract()
    v = version()
    if v.get('protocolNamespace') != 'Loom' or v.get('compatibilityEpoch') != 1 or v.get('acceptsEarlierNamespace') is not False:
        raise ValueError('Unexpected protocol compatibility epoch')
    expected = v['components']
    for key, path in [('client', 'apps/loom/pubspec.yaml'), ('nodeUi', 'apps/loom_node_ui/pubspec.yaml')]:
        actual = re.search(r'^version:\s*(\S+)', (ROOT / path).read_text(), re.M).group(1)
        if actual != expected[key]:
            raise ValueError(f'{path}: {actual} != {expected[key]}')
    if json.loads((ROOT / 'services/loom_server/package.json').read_text())['version'] != expected['node']:
        raise ValueError('Node version mismatch')
    actual = re.search(r'const version = "([^"]+)"', (ROOT / 'tools/loom_node_manager/main.go').read_text()).group(1)
    if actual != expected['terminalManager']:
        raise ValueError('Manager version mismatch')
    if v['version'] != '0.1.0-alpha.1' or v['published'] is not False:
        raise ValueError('Unexpected alpha release metadata')
    if 'GNU GENERAL PUBLIC LICENSE' not in (ROOT / 'LICENSE').read_text():
        raise ValueError('GPL license missing')
    if os.getenv('GITHUB_REF_TYPE') == 'tag':
        if os.getenv('GITHUB_REPOSITORY') != '0800x/Loom':
            raise ValueError('Release tags may build only in 0800x/Loom')
        if os.getenv('GITHUB_REF_NAME') != 'v' + v['version']:
            raise ValueError('Tag/version mismatch')
        if os.getenv('APPROVED_LOOM_REVISION') != git('rev-parse', 'HEAD'):
            raise ValueError('Exact revision requires explicit approval in repository variables')
        if os.getenv('APPROVED_LOOM_TAG') != os.getenv('GITHUB_REF_NAME'):
            raise ValueError('Tag requires explicit approval in repository variables')
    print(json.dumps({'version': v['version'], 'components': expected, 'revision': git('rev-parse', 'HEAD')}))

def native_arch(data):
    if data[:4] == b'\x7fELF':
        endian = '<' if data[5] == 1 else '>'
        return {40: 'armeabi-v7a', 183: 'arm64', 62: 'x64'}.get(struct.unpack_from(endian + 'H', data, 18)[0], 'unknown')
    if data[:2] == b'MZ':
        offset = struct.unpack_from('<I', data, 60)[0]
        if data[offset:offset + 4] != b'PE\0\0':
            raise ValueError('Invalid PE header')
        return {0x8664: 'x64', 0xAA64: 'arm64'}.get(struct.unpack_from('<H', data, offset + 4)[0], 'unknown')
    # Thin Mach-O; fat binaries are rejected unless checked separately by lipo.
    magic = data[:4]
    if magic in (b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf'):
        endian = '<' if magic == b'\xcf\xfa\xed\xfe' else '>'
        return {0x01000007: 'x64', 0x0100000C: 'arm64'}.get(struct.unpack_from(endian + 'I', data, 4)[0], 'unknown')
    raise ValueError('Unrecognized native binary')

def inspect_apk(path, abis):
    mapping = {'armeabi-v7a': 'armeabi-v7a', 'arm64-v8a': 'arm64', 'x86_64': 'x64'}
    with zipfile.ZipFile(path) as archive:
        actual = {p.split('/')[1] for p in archive.namelist() if p.endswith('/libloom_mls.so')}
        if actual != set(abis):
            raise ValueError(f'{path}: MLS ABIs {actual}, expected {set(abis)}')
        for abi in abis:
            p = f'lib/{abi}/libloom_mls.so'
            if native_arch(archive.read(p)) != mapping[abi]:
                raise ValueError('MLS native architecture mismatch: ' + p)
            if f'lib/{abi}/libflutter.so' not in archive.namelist():
                raise ValueError('Missing Flutter runtime for ' + abi)
    print('Verified native MLS and Flutter libraries:', path)

def toolchain_version(command):
    arguments = shlex.split(command)
    if not arguments:
        raise ValueError('Empty toolchain command')
    executable = shutil.which(arguments[0])
    if executable is None:
        raise ValueError('Toolchain executable unavailable: ' + arguments[0])
    # Resolve PATHEXT on Windows, including Flutter's flutter.bat. No shell
    # substitution or credentials are involved in recording tool versions.
    return subprocess.check_output([executable, *arguments[1:]], text=True,
                                   stderr=subprocess.STDOUT).strip()

def runtime_dependencies(executable, output):
    text = subprocess.check_output(['ldd', str(Path(executable).resolve())],
                                   text=True, stderr=subprocess.STDOUT)
    if 'not found' in text:
        raise ValueError('Missing Linux runtime dependency')
    replacements = {str(Path.home()): '/build-home', str(ROOT): '/loom'}
    if os.getenv('GITHUB_WORKSPACE'):
        replacements[os.environ['GITHUB_WORKSPACE']] = '/loom'
    for prefix in sorted(replacements, key=len, reverse=True):
        text = text.replace(prefix, replacements[prefix])
    Path(output).write_text(text)

def manifest(args):
    files = sorted(Path(args.directory).glob('*'))
    files = [f for f in files if f.is_file() and f.name not in ('build-manifest.json', 'SHA256SUMS')]
    if not files:
        raise ValueError('No artifacts')
    toolchains = {}
    for spec in args.toolchain:
        name, command = spec.split('=', 1)
        toolchains[name] = toolchain_version(command)
    result = {'product': 'Loom', 'version': version()['version'], 'revision': git('rev-parse', 'HEAD'),
              'tree': git('rev-parse', 'HEAD^{tree}'), 'platform': args.platform,
              'architecture': args.arch, 'signing': args.signing, 'toolchains': toolchains,
              'files': [{'name': f.name, 'sha256': sha(f), 'size': f.stat().st_size} for f in files]}
    Path(args.directory, 'build-manifest.json').write_text(json.dumps(result, indent=2) + '\n')
    checksums(args.directory)

def checksums(directory):
    directory = Path(directory)
    files = sorted(f for f in directory.rglob('*') if f.is_file() and f.name != 'SHA256SUMS')
    directory.joinpath('SHA256SUMS').write_text(''.join(f'{sha(f)}  {f.relative_to(directory).as_posix()}\n' for f in files))

def export(path):
    files = git('ls-files', '-z').split('\0')
    forbidden_parts = {'.git', '.dart_tool', 'node_modules', 'target', 'build', '.gradle', '.idea', '.vscode', '__pycache__'}
    with tarfile.open(path, 'w:gz') as archive:
        for name in sorted(filter(None, files)):
            p = Path(name)
            if any(part in forbidden_parts for part in p.parts) or p.name in ('key.properties', 'local.properties', '.env'):
                continue
            if p.suffix.lower() in ('.jks', '.keystore', '.log', '.apk', '.aab', '.exe', '.dll', '.so', '.dylib'):
                continue
            file = ROOT / name
            if file.is_symlink() or not file.is_file():
                raise ValueError('Unexpected export entry: ' + name)
            info = archive.gettarinfo(str(file), 'Loom/' + p.as_posix())
            info.uid = info.gid = 0
            info.uname = info.gname = ''
            info.mtime = 0
            with file.open('rb') as stream:
                archive.addfile(info, stream)

def audit(directory, output):
    patterns = {
        'personal-build-path': rb'(?<![\w./])(?:C:\\Users\\[^\\\s"\']+\\|/Users/[^/\s"\']+/|/home/(?!\*)[^/\s]+/)',
        'private-donation-url': rb'nowpayments[^\s"\']{0,200}api_key=',
    }
    findings = []
    for p in sorted(Path(directory).rglob('*')):
        if not p.is_file() or any(s in p.parts for s in ('.git', 'node_modules', 'target', 'build', '.dart_tool', '__pycache__')):
            continue
        data = p.read_bytes()
        for kind, expression in patterns.items():
            if kind == 'personal-build-path' and p.relative_to(directory).as_posix() in ('scripts/release.py', 'scripts/audit-artifact.py'):
                continue # Scanner signatures are not an embedded personal path.
            hits = list(re.finditer(expression, data))
            if hits:
                findings.append({'path': p.relative_to(directory).as_posix(), 'kind': kind, 'count': len(hits)})
    Path(output).write_text(json.dumps({'findings': findings, 'anonymityGuaranteed': False,
        'notes': 'Required copyright and authenticated compatibility strings remain. Scan is not a secret detector or proof of anonymity.'}, indent=2) + '\n')
    if findings:
        raise ValueError('Review identifying paths or private donation URLs in audit report')

def main():
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('preflight')
    p = commands.add_parser('inspect-apk'); p.add_argument('path'); p.add_argument('abis', nargs='+')
    p = commands.add_parser('inspect-native'); p.add_argument('path'); p.add_argument('arch')
    p = commands.add_parser('runtime-dependencies'); p.add_argument('executable'); p.add_argument('output')
    p = commands.add_parser('manifest')
    for name in ('directory', 'platform', 'arch', 'signing'): p.add_argument('--' + name, required=True)
    p.add_argument('--toolchain', action='append', default=[])
    p = commands.add_parser('checksums'); p.add_argument('directory')
    p = commands.add_parser('export'); p.add_argument('path')
    p = commands.add_parser('audit'); p.add_argument('directory'); p.add_argument('output')
    args = parser.parse_args()
    if args.command == 'preflight': preflight()
    elif args.command == 'inspect-apk': inspect_apk(args.path, args.abis)
    elif args.command == 'inspect-native':
        actual = native_arch(Path(args.path).read_bytes())
        if actual != args.arch: raise ValueError(f'Native architecture {actual} != {args.arch}')
        print('Verified native architecture:', actual)
    elif args.command == 'manifest': manifest(args)
    elif args.command == 'runtime-dependencies': runtime_dependencies(args.executable, args.output)
    elif args.command == 'checksums': checksums(args.directory)
    elif args.command == 'export': export(args.path)
    elif args.command == 'audit': audit(args.directory, args.output)

if __name__ == '__main__': main()
