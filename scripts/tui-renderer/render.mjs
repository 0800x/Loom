// Decode the real PTY stream with xterm's VT parser, including cursor erases.
import xterm from '@xterm/headless';
const { Terminal } = xterm;
const chunks = [];
for await (const chunk of process.stdin) chunks.push(chunk);
const terminal = new Terminal({ cols: 120, rows: 40, allowProposedApi: true });
await new Promise(resolve => terminal.write(Buffer.concat(chunks), resolve));
function color(cell, foreground) {
  const value = foreground ? cell.getFgColor() : cell.getBgColor();
  if (foreground ? cell.isFgRGB() : cell.isBgRGB()) return '#' + value.toString(16).padStart(6, '0');
  if (foreground ? cell.isFgPalette() : cell.isBgPalette()) return value;
  return null;
}
const lines = [], cells = [];
for (let y = 0; y < 40; y++) {
  const line = terminal.buffer.active.getLine(terminal.buffer.active.viewportY + y);
  lines.push(line.translateToString(false));
  const row = [];
  for (let x = 0; x < 120; x++) {
    const cell = line.getCell(x);
    row.push([cell.getChars(), color(cell, true), color(cell, false), Boolean(cell.isInverse())]);
  }
  cells.push(row);
}
process.stdout.write(JSON.stringify({ lines, cells }));
terminal.dispose();
