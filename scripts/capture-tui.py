#!/usr/bin/env python3
"""Run the actual read-only Bubble Tea fixture in a PTY and render its terminal cells.
Requires npm ci in scripts/tui-renderer, Node.js, Go and Pillow. Captures no production services or installations.
"""
import errno
import fcntl
import os
from pathlib import Path
import pty
import select
import struct
import sys
import termios
import time
import json
import subprocess
import importlib.metadata
from PIL import Image, ImageDraw, ImageFont

binary = str(Path(sys.argv[1]).resolve())
out = Path(sys.argv[2]); out.mkdir(parents=True, exist_ok=True)
columns, rows = 120, 40
pid, fd = pty.fork()
if pid == 0:
    os.environ.update(TERM='xterm-256color', COLORTERM='truecolor')
    os.execv(binary, [binary, '--capture-fixture'])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', rows, columns, 0, 0))
recording = bytearray()

def read_for(seconds):
    until = time.monotonic() + seconds
    while time.monotonic() < until:
        if not select.select([fd], [], [], .05)[0]: continue
        try:
            data = os.read(fd, 65536)
        except OSError as error:
            if error.errno == errno.EIO: return
            raise
        if not data: return
        recording.extend(data)
        if b'\x1b[6n' in data: os.write(fd, b'\x1b[1;1R')
        if b'\x1b]11;?' in data: os.write(fd, b'\x1b]11;rgb:1111/1313/1818\x1b\\')
        if b'\x1b[c' in data: os.write(fd, b'\x1b[?1;2c')

font = ImageFont.truetype('/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf', 18)
palette = ['#000000','#cd0000','#00cd00','#cdcd00','#0000ee','#cd00cd','#00cdcd','#e5e5e5',
           '#7f7f7f','#ff0000','#00ff00','#ffff00','#5c5cff','#ff00ff','#00ffff','#ffffff']
def color(value, fallback):
    if value is None: return fallback
    if isinstance(value, str): return value
    if value < 16: return palette[value]
    if value >= 232:
        grey = 8 + (value - 232) * 10
        return (grey, grey, grey)
    value -= 16
    levels = [0,95,135,175,215,255]
    return (levels[value // 36], levels[(value // 6) % 6], levels[value % 6])

def capture(name):
    renderer = Path(__file__).parent / 'tui-renderer/render.mjs'
    decoded = json.loads(subprocess.check_output(['node', str(renderer)], input=bytes(recording)))
    image = Image.new('RGB', (columns*11+32, rows*24+32), '#111318'); draw = ImageDraw.Draw(image)
    for y, row in enumerate(decoded['cells']):
        for x, (text, fg, bg, inverse) in enumerate(row):
            background, foreground = color(bg, '#111318'), color(fg, '#e9edf2')
            if inverse: foreground, background = background, foreground
            draw.rectangle((16+x*11,16+y*24,27+x*11,40+y*24), fill=background)
            if text: draw.text((16+x*11,17+y*24),text,font=font,fill=foreground)
    image.save(out / ('tui-' + name + '-en.png'))
    (out / ('tui-' + name + '-en.txt')).write_text('\n'.join(decoded['lines'])+'\n')

try:
    read_for(1.5); capture('overview')
    for name, steps in [('services',1),('calling',5),('updates',10)]:
        os.write(fd, b'\x1b[B' * steps); read_for(.7); capture(name)
    (out / 'tui-session.ansi').write_bytes(recording)
    build = subprocess.check_output(['go', 'version', '-m', binary], text=True).splitlines()
    (out / 'tui-renderer.json').write_text(json.dumps({'xtermHeadless': '6.0.0',
        'pillow': importlib.metadata.version('Pillow'), 'go': build[0].split(': ',1)[-1],
        'binaryModules': [line.strip() for line in build[1:]],
        'manager': subprocess.check_output([binary, '--version'], text=True).strip()}, indent=2)+'\n')
finally:
    os.write(fd,b'q'); read_for(.2); os.close(fd); os.waitpid(pid,0)
