// term.test.ts - miniVIC TERM on the bo6502-emulator core with the BIOS KEYB/SD
import { loadApp, sdImage, Run, assert, runFrames, DOC_BASE } from './harness';
import { SerialBoard } from 'EMU/src/boards/Boards';

export default async function () {
  const names: [string, string][] = [['write', 'Write'], ['calc', 'Calc'], ['file', 'File'], ['mon', 'Mon'], ['desk', 'Desk'], ['term', 'Term']];
  const apps = names.map(([f, n]) => loadApp(f, n));
  const img = sdImage(apps);
  const r = new Run(apps[5], img, 6);
  const acia = r.m.board<SerialBoard>('serial')!.acia;
  const recv = (s: string) => { for (const c of s) acia.receive(c.charCodeAt(0)); runFrames(r.m, 3); r.settle(); };
  const sent = () => { const s = r.serialText(); r.serial.length = 0; return s; };
  assert(/\[APP\] TERM/.test(sent()) && r.row(0).includes('19200') && acia.command === 0x89, 'start\n' + r.screen());
  console.log(`      start ok, ${apps[5].bin.length} bytes, receive interrupt on (command $89)`);

  // receiving: text, CR LF, ANSI clear / home / clear to the end of the row
  recv('HELLO\r\nWORLD');
  assert(r.row(1).startsWith('HELLO') && r.row(2).startsWith('WORLD'), 'text\n' + r.screen());
  recv('\x1b[2J\x1b[HX\x1b[5CY\r\nABCDEF\x1b[3D\x1b[K');
  assert(r.row(1).startsWith('X     Y') && r.row(2).trimEnd() === 'ABC', 'ANSI\n' + r.screen());
  // (the emulated W65C51 hands over every byte at once, with no baud timing: one row at a
  // time, as a real line would, or the 256-byte ring overflows)
  for (let i = 1; i <= 30; i++) recv(`LINE ${i}\r\n`);
  const rows = Array.from({ length: 23 }, (_, i) => r.row(i + 1).trim());
  const last = rows.lastIndexOf('LINE 30');
  const first = Number(rows[1].slice(5));
  assert(last >= 21 && rows.slice(1, last + 1).every((x, i) => x === `LINE ${first + i}`) && rows.slice(last + 1).every(x => x === '')
    && r.row(0).includes('TERM'), 'scrolling\n' + r.screen());
  console.log('      text, CR LF, ESC[2J ESC[H ESC[nC ESC[nD ESC[K, 30 rows scrolled ok');

  // typing goes out; arrows as ESC[A..D; Enter = CR (CR LF with F3); local echo with F2
  r.type('abc'); r.key('Enter'); r.key('ArrowUp'); r.key('ArrowLeft'); r.settle();
  const s1 = sent();
  assert(s1 === 'abc\r\x1b[A\x1b[D', 'sent: ' + JSON.stringify(s1));
  r.key('F3'); r.key('F2'); r.settle();
  r.type('z'); r.key('Enter'); r.settle();
  assert(sent() === 'z\r\n' && r.screen().includes('z'), 'CR LF and echo');
  r.key('F3'); r.key('F2'); r.settle();
  // a key typed while bytes arrive: the key goes out, the bytes reach the screen
  for (let i = 0; i < 40; i++) acia.receive(0x2E);
  r.key('KeyQ'); r.settle();
  assert(sent() === 'q' && r.screen().includes('.'.repeat(30)), 'key during reception: ' + JSON.stringify(r.serialText()));
  console.log('      keys out, arrows ESC[A ESC[D, F3 CR LF, F2 echo, a key during reception ok');

  // capture, save as text, send it back
  r.key('F4'); r.settle();
  recv('ONE\r\nTWO\nTHREE\r\n');
  r.key('F4'); r.settle();
  r.key('F5'); r.type('log', false); r.key('Enter'); r.settle();
  assert(r.screen().includes('[CAPTURE SAVED]'), 'capture saved\n' + r.screen());
  const idx = img.subarray(DOC_BASE * 512, DOC_BASE * 512 + 512);
  const k = [1, 2, 3].find(i => idx[i * 32] === 1)!;
  const len = idx[k * 32 + 1] | (idx[k * 32 + 2] << 8);
  const txt = String.fromCharCode(...img.subarray((DOC_BASE + k * 40) * 512, (DOC_BASE + k * 40) * 512 + len));
  assert(txt === 'ONE\rTWO\rTHREE\r', 'captured text: ' + JSON.stringify(txt));
  r.shot('screen');
  sent();
  r.key('F6'); r.settle(); r.key('Enter'); r.settle();
  assert(sent() === 'ONE\rTWO\rTHREE\r', 'sent document: ' + JSON.stringify(r.serialText()));
  console.log(`      F4 capture, F5 saved as text (${len} bytes, LF folded into CR), F6 sent back ok`);

  // speed, then out: the serial line as the BIOS wants it
  r.key('F7'); r.settle();
  assert(acia.control === 0x16 && r.row(0).includes('  300'), 'speed 300');
  r.key('F10');
  for (let i = 0; i < 120; i++) r.m.runFrame();
  assert(r.m.cpu.pc >= 0x8000 && acia.command === 0x8B && acia.control === 0x1F, 'back to the BIOS, serial restored');
  console.log('      F7 300 baud, F10 back to the BIOS with $8B / $1F restored');
}
