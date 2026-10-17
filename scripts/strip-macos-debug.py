"""Strip Mach-O debug symbol tables before signing, preserving stripped vendors.

Some already-stripped vendor frameworks have a LINKEDIT layout Apple's strip
cannot rewrite. Inspect N_STAB entries first; do not rewrite those binaries.
Failures while stripping actual debug information remain fatal.
"""
from pathlib import Path
import struct
import os
import subprocess
import sys


def has_debug_symbols(data):
    magic = bytes(data[:4])
    thin = {b'\xce\xfa\xed\xfe': ('<', 28, 12), b'\xcf\xfa\xed\xfe': ('<', 32, 16),
            b'\xfe\xed\xfa\xce': ('>', 28, 12), b'\xfe\xed\xfa\xcf': ('>', 32, 16)}
    fat = {b'\xca\xfe\xba\xbe': ('>', False), b'\xbe\xba\xfe\xca': ('<', False),
           b'\xca\xfe\xba\xbf': ('>', True), b'\xbf\xba\xfe\xca': ('<', True)}
    if magic in fat:
        endian, wide = fat[magic]
        count, = struct.unpack_from(endian + 'I', data, 4)
        stride = 32 if wide else 20
        found = False
        for index in range(count):
            offset, size = struct.unpack_from(endian + ('QQ' if wide else 'II'), data, 8 + index * stride + 8)
            if offset + size > len(data):
                raise ValueError('Truncated universal Mach-O slice')
            found = has_debug_symbols(data[offset:offset + size]) or found
        return found
    if magic not in thin:
        return False
    endian, header, stride = thin[magic]
    commands, command_bytes = struct.unpack_from(endian + 'II', data, 16)
    end = header + command_bytes
    if end > len(data):
        raise ValueError('Truncated Mach-O load commands')
    position = header
    found = False
    for _ in range(commands):
        command, size = struct.unpack_from(endian + 'II', data, position)
        if size < 8 or position + size > end:
            raise ValueError('Invalid Mach-O load command')
        if command == 2:  # LC_SYMTAB
            if size < 24:
                raise ValueError('Truncated Mach-O symbol command')
            offset, count = struct.unpack_from(endian + 'II', data, position + 8)
            if offset + count * stride > len(data):
                raise ValueError('Truncated Mach-O symbol table')
            found = any(data[offset + index * stride + 4] & 0xe0 for index in range(count)) or found
        position += size
    return found


def strip_app(app):
    stripped = skipped = 0
    root = os.environ.get('GITHUB_WORKSPACE', str(Path(__file__).resolve().parents[1]))
    prefixes = {value.encode() for value in (root, root.replace('\\', '/'))}
    for path in sorted(Path(app).rglob('*')):
        if not path.is_file() or path.is_symlink():
            continue
        data = path.read_bytes()
        # Preserve vendor frameworks and already-remapped output. Only debug
        # tables carrying this checkout's unmapped path require cleanup. The
        # final artifact audit still rejects any remaining checkout path.
        if not any(prefix in data for prefix in prefixes) or not has_debug_symbols(data):
            skipped += 1
            continue
        subprocess.run(['xcrun', 'strip', '-S', str(path)], check=True)
        if has_debug_symbols(path.read_bytes()):
            raise ValueError('Mach-O debug symbols remain after strip')
        stripped += 1
    print(f'Mach-O debug cleanup: {stripped} symbol tables stripped; {skipped} files preserved')


if __name__ == '__main__':
    strip_app(sys.argv[1])
