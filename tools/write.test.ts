// write.test.ts - miniVIC WRITE on the bo6502-emulator core with the BIOS KEYB/SD
// The editor is loaded from the SD menu like on the real machine, then driven with PS/2 keys.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { buildMachine, defaultConfig } from 'EMU/src/machines/profiles';
import { buildSdImage } from 'EMU/src/machines/sdimage';
import { SdCardBoard, KeyboardBoard, SerialBoard } from 'EMU/src/boards/Boards';
import { screenText, runFrames, assert, writePng } from 'EMU/tests/helpers';
import { TMS_PALETTE, SCREEN_W, SCREEN_H } from 'EMU/src/devices/TMS9918A';

declare const __ROOT__: string;
const ROOT = __ROOT__;
const BINF = process.env.WRITE_BIN || join(ROOT, 'bin', 'write.bin');   // (another build: WRITE_BIN=<.bin>, its .lst next to it)
const BIN = new Uint8Array(readFileSync(BINF));
const SYM: Record<string, number> = {};
{
  const lst = readFileSync(BINF.replace(/\.bin$/, '.lst'), 'latin1');
  const part = lst.slice(lst.indexOf('Symbols by value:'));
  for (const m of part.matchAll(/^([0-9A-F]{4,8}) (\S+)/gm)) SYM[m[2]] = parseInt(m[1], 16);
}
const BUF = 0x3000, BUF_END = 0x8000, DOC_BASE = 16384;

// ---------------------------------------------------------------- machine
function sdImage(): Uint8Array {
  const base = buildSdImage([{ name: 'WRITE - APP', data: BIN, load: 0x0FD0, entry: 0x1000, run: true }]);
  const img = new Uint8Array(9 * 1024 * 1024);
  img.set(base);
  img[16 + 6] = 2; img[16 + 7] = 5;           // type APP, serial name "WRITE"
  return img;
}
let idleHits = 0, keyCycles = 0, worst = 0, worstWhat = '', inKey = -1;
let what = '';
let lastPoll = -1, lastCaller = 0, maxGap = 0, gapFrom = 0, gapTo = 0, pollOn = false;
const symAt = (a: number) => {
  let best = '', ba = -1;
  for (const [k, v] of Object.entries(SYM)) if (v <= a && v > ba && v >= 0x1000 && v < 0x3000) { best = k; ba = v; }
  return `$${a.toString(16)} (${best}+${a - ba})`;
};
const gapReport = () => `longest time without a poll ${maxGap} cycles, from ${symAt(gapFrom)} to ${symAt(gapTo)}`;
function machine(img: Uint8Array) {
  const m = buildMachine(defaultConfig('minivic'));
  m.loadRom(new Uint8Array(readFileSync(process.env.BIOS_ROM!)));
  (m.board<SdCardBoard>('sdcard')! as any).card.insert(img);
  m.powerOn();
  m.breakpoint = (pc: number) => {
    if (pc === 0xFD03) {                       // JT_CHRIN: the longest time between two polls
      const s = m.cpu.sp, r = m.ram;
      const caller = ((r[0x100 + ((s + 6) & 255)] | (r[0x100 + ((s + 7) & 255)] << 8)) - 2) & 0xFFFF;
      const gap = m.cpu.cycles - lastPoll;
      if (lastPoll >= 0 && gap > maxGap && pollOn) { maxGap = gap; gapFrom = lastCaller; gapTo = caller; }
      lastPoll = m.cpu.cycles; lastCaller = caller;
    }
    if (pc === SYM.DOKEY && inKey < 0) inKey = m.cpu.cycles;
    if (pc === SYM.WAITKEY) idleHits++;       // a prompt or a list waiting for a key
    if (pc === SYM.IDLE) {
      idleHits++;
      if (inKey >= 0) {
        const c = m.cpu.cycles - inKey;
        if (c > worst) { worst = c; worstWhat = what; }
        keyCycles = c;
        inKey = -1;
      }
    }
    return false;
  };
  runFrames(m, 90);
  return m;
}
const kb = (m: any) => m.board<KeyboardBoard>('keyboard')!.keyboard;
function settle(m: any, max = 3000) {
  for (let f = 0; f < max; f++) {
    const h = idleHits;
    runFrames(m, 1);
    if (idleHits - h > 5 && kbIdle(m)) return f;
  }
  throw new Error('the editor does not go back to idle (' + what + ')');
}
const kbIdle = (m: any) => { const k = kb(m) as any; return k.queue.length === 0 && k.packet.length === 0; };
function key(m: any, code: string, mods: string[] = [], hold = 1) {
  const k = kb(m);
  for (const x of mods) k.keyDown(x);
  k.keyDown(code); runFrames(m, hold); k.keyUp(code);
  for (const x of mods) k.keyUp(x);
  runFrames(m, 1);
}
const ctrl = (m: any, letter: string) => key(m, 'Key' + letter.toUpperCase(), ['ControlLeft']);
const SHIFTED: Record<string, string> = {
  '!': 'Digit1', '@': 'Digit2', '#': 'Digit3', '$': 'Digit4', '%': 'Digit5', '^': 'Digit6', '&': 'Digit7',
  '*': 'Digit8', '(': 'Digit9', ')': 'Digit0', ':': 'Semicolon', '"': 'Quote', '?': 'Slash', '_': 'Minus', '+': 'Equal',
};
const PLAIN: Record<string, string> = {
  ' ': 'Space', '.': 'Period', ',': 'Comma', ';': 'Semicolon', "'": 'Quote', '-': 'Minus', '/': 'Slash', '=': 'Equal',
  '\n': 'Enter',
};
function type(m: any, s: string, wait = true) {
  for (const ch of s) {
    if (/[a-z]/.test(ch)) key(m, 'Key' + ch.toUpperCase());
    else if (/[A-Z]/.test(ch)) key(m, 'Key' + ch, ['ShiftLeft']);
    else if (/[0-9]/.test(ch)) key(m, 'Digit' + ch);
    else if (PLAIN[ch]) key(m, PLAIN[ch]);
    else if (SHIFTED[ch]) key(m, SHIFTED[ch], ['ShiftLeft']);
    else throw new Error('no key for ' + JSON.stringify(ch));
  }
  if (wait) settle(m);
}
function text(m: any): string {
  const r = m.ram, gs = r[0x50] | (r[0x51] << 8), ge = r[0x52] | (r[0x53] << 8);
  let s = '';
  for (let a = BUF; a < gs; a++) s += String.fromCharCode(r[a]);
  for (let a = ge; a < BUF_END; a++) s += String.fromCharCode(r[a]);
  return s.replace(/\r/g, '\n');
}
const cursor = (m: any) => (m.ram[0x50] | (m.ram[0x51] << 8)) - BUF;
function row(m: any, r: number): string {   // screen row without the inverse bit
  const v = m.vdu!.vdp.vram;
  let s = '';
  for (let c = 0; c < 40; c++) s += String.fromCharCode(v[0x0800 + r * 40 + c] & 0x7F);
  return s;
}
function shot(m: any, name: string) {
  const vdp = m.vdu!.vdp;
  const dir = join(ROOT, 'screenshots');
  mkdirSync(dir, { recursive: true });
  const f = writePng('write_' + name, SCREEN_W * 2, SCREEN_H * 2,
    (x, y) => TMS_PALETTE[vdp.frame[(y >> 1) * SCREEN_W + (x >> 1)]]);
  writeFileSync(join(dir, 'write_' + name + '.png'), readFileSync(f));
}
// the text as the editor shows it: screen rows 1-22 with the inverse bit removed
function screenRows(m: any): string[] {
  const vdp = m.vdu!.vdp, out: string[] = [];
  for (let r = 1; r <= 22; r++) {
    let s = '';
    for (let c = 0; c < 40; c++) s += String.fromCharCode(vdp.vram[0x0800 + r * 40 + c] & 0x7F);
    out.push(s);
  }
  return out;
}

// ---------------------------------------------------------------- tests
const PARA = 'In the early eighties a home computer was a keyboard, a television and a cassette or a disk. ' +
  'Word processors like WordStar or Electric Pencil turned it into a typewriter that never wasted paper: ' +
  'you could move a paragraph, find a word and print the letter only when it was right.';

export default async function () {
  const img = sdImage();
  const m = machine(img);
  const serial: number[] = [];
  m.board<SerialBoard>('serial')!.acia.onTransmit = (b: number) => serial.push(b);
  // from the SD menu, like on the machine
  key(m, 'Digit3'); runFrames(m, 150);
  assert(screenText(m).includes('SD PROGRAMS MENU'), 'SD menu not found\n' + screenText(m));
  serial.length = 0;
  key(m, 'Digit1');
  for (let f = 0; f < 1500 && idleHits === 0; f++) runFrames(m, 1);
  assert(idleHits > 0, 'the editor did not start');
  settle(m);
  const line = String.fromCharCode(...serial).match(/\[APP\][^\r]*/);
  assert(line && line[0] === '[APP] WRITE', 'serial line: ' + JSON.stringify(String.fromCharCode(...serial)));
  assert(row(m, 0).includes('NO NAME') && row(m, 23).includes('MINIVIC WRITE'), 'start screen\n' + screenText(m));
  console.log(`      start from the SD menu ok, serial "${line![0]}", ${BIN.length} bytes, code end $${SYM.CODE_END.toString(16)}`);
  shot(m, 'start');

  // typing and word wrap
  what = 'typing';
  pollOn = true; maxGap = 0;
  type(m, PARA);
  console.log('      ' + gapReport());
  assert(text(m) === PARA, 'typed text differs:\n' + text(m));
  const rows = screenRows(m).map(s => s.trimEnd()).filter(s => s);
  const joined = rows.join(' ').replace(/ +/g, ' ');
  assert(joined === PARA, 'wrapped text differs:\n' + rows.join('\n'));
  for (let i = 0; i + 1 < rows.length; i++) {
    const next = rows[i + 1].split(' ')[0];
    // a row keeps the space after its last word, so a word fits only with that space within 40 columns
    assert(rows[i].trimEnd().length + 1 + next.length + 1 > 40, `row ${i + 1} could hold the next word: ${rows[i]} | ${next}`);
  }
  console.log(`      typed ${PARA.length} characters, ${rows.length} rows wrapped at the words, worst key ${worst} cycles (${(worst / 16667).toFixed(1)} frames)`);
  shot(m, 'typing');

  // cursor keys
  what = 'cursor';
  key(m, 'Home'); settle(m);
  const lastRowStart = PARA.length - rows[rows.length - 1].length;
  assert(cursor(m) === lastRowStart, `Home: ${cursor(m)} expected ${lastRowStart}`);
  key(m, 'ArrowUp'); settle(m);
  const prevStart = lastRowStart - (rows[rows.length - 2].length + 1);
  assert(cursor(m) === prevStart, `Up: ${cursor(m)} expected ${prevStart}`);
  ctrl(m, 'q'); key(m, 'KeyR'); settle(m);
  assert(cursor(m) === 0, '^QR: ' + cursor(m));
  ctrl(m, 'f'); ctrl(m, 'f'); settle(m);
  assert(cursor(m) === 'In the '.length, '^F ^F: ' + cursor(m));
  ctrl(m, 'd'); ctrl(m, 'd'); ctrl(m, 's'); settle(m);
  assert(cursor(m) === 8, '^D ^D ^S: ' + cursor(m));
  key(m, 'ArrowDown'); key(m, 'ArrowDown'); key(m, 'ArrowUp'); settle(m);
  assert(cursor(m) === rows[0].length + 1 + 8, 'Down Down Up keeps the column: ' + cursor(m));
  key(m, 'End'); settle(m);
  ctrl(m, 'q'); key(m, 'KeyC'); settle(m);
  assert(cursor(m) === PARA.length, '^QC: ' + cursor(m));
  console.log('      cursor: Home, Up, ^QR, ^F, ^D ^S, Down/Up column, ^QC ok');

  // editing
  what = 'editing';
  type(m, '\nSecond paragraph.');
  key(m, 'Backspace'); type(m, '!');
  ctrl(m, 'q'); key(m, 'KeyR'); key(m, 'Delete'); key(m, 'Delete'); key(m, 'Delete'); settle(m);
  assert(text(m) === PARA.slice(3) + '\nSecond paragraph!', 'Delete/Backspace: ' + JSON.stringify(text(m).slice(-30)));
  type(m, 'In ');
  ctrl(m, 'q'); key(m, 'KeyC'); ctrl(m, 'y'); settle(m);
  assert(text(m) === PARA + '\n', '^Y: ' + JSON.stringify(text(m).slice(-30)));
  key(m, 'Backspace'); settle(m);
  ctrl(m, 'q'); key(m, 'KeyR'); ctrl(m, 't'); settle(m);
  assert(text(m) === PARA.slice(3), '^T: ' + JSON.stringify(text(m).slice(0, 20)));
  type(m, 'In ');
  key(m, 'Insert'); type(m, 'ON'); key(m, 'Insert'); settle(m);
  assert(text(m).startsWith('In ONe early'), 'overwrite: ' + text(m).slice(0, 20));
  key(m, 'Backspace'); key(m, 'Backspace'); type(m, 'th');
  assert(text(m) === PARA, 'text after the edits: ' + text(m).slice(0, 30));
  console.log('      editing: Delete, Backspace, ^Y, ^T, Insert/overwrite ok');

  // block copy / move / delete
  what = 'block';
  ctrl(m, 'q'); key(m, 'KeyR'); ctrl(m, 'k'); key(m, 'KeyB');
  ctrl(m, 'f'); ctrl(m, 'f'); ctrl(m, 'f'); ctrl(m, 'k'); key(m, 'KeyK');   // "In the early "
  ctrl(m, 'q'); key(m, 'KeyC'); ctrl(m, 'k'); key(m, 'KeyC'); settle(m);
  assert(text(m) === PARA + 'In the early ', 'copy: ' + text(m).slice(-20));
  shot(m, 'block');
  ctrl(m, 'k'); key(m, 'KeyY'); settle(m);
  assert(text(m) === PARA, 'block delete: ' + text(m).slice(-20));
  ctrl(m, 'q'); key(m, 'KeyR'); ctrl(m, 'k'); key(m, 'KeyB'); ctrl(m, 'f'); ctrl(m, 'k'); key(m, 'KeyK');   // "In "
  ctrl(m, 'q'); key(m, 'KeyC'); ctrl(m, 'k'); key(m, 'KeyV'); settle(m);
  assert(text(m) === PARA.slice(3) + 'In ', 'move to the end: ' + text(m).slice(-10));
  ctrl(m, 'q'); key(m, 'KeyR'); ctrl(m, 'k'); key(m, 'KeyV'); settle(m);
  assert(text(m) === PARA, 'move back to the start: ' + text(m).slice(0, 10));
  ctrl(m, 'k'); key(m, 'KeyH'); settle(m);
  console.log('      block: ^KB ^KK, ^KC copy, ^KY delete, ^KV move both ways, ^KH ok');

  // find / replace
  what = 'find';
  maxGap = 0;
  ctrl(m, 'q'); key(m, 'KeyR');
  ctrl(m, 'q'); key(m, 'KeyF'); type(m, 'WORD'); key(m, 'Enter'); settle(m);
  const w1 = PARA.toUpperCase().indexOf('WORD') + 4;
  assert(cursor(m) === w1, `find: ${cursor(m)} expected ${w1}`);
  ctrl(m, 'l'); settle(m);
  const w2 = PARA.toUpperCase().indexOf('WORD', w1) + 4;
  assert(cursor(m) === w2, `find again: ${cursor(m)} expected ${w2}`);
  ctrl(m, 'l'); ctrl(m, 'l'); settle(m);
  assert(row(m, 23).includes('NOT FOUND'), 'not found: ' + row(m, 23));
  ctrl(m, 'q'); key(m, 'KeyR');
  ctrl(m, 'q'); key(m, 'KeyA'); for (let i = 0; i < 4; i++) key(m, 'Backspace');
  type(m, 'a '); key(m, 'Enter'); type(m, 'A '); key(m, 'Enter'); settle(m);
  const nA = PARA.split(/a /i).length - 1;
  assert(text(m) === PARA.replace(/a /gi, 'A ') && row(m, 23).includes('REPLACED') && row(m, 23).includes(String(nA)),
    'replace: ' + row(m, 23) + '\n' + text(m));
  console.log(`      find, ^L again, not found, ^QA replaced ${nA} ok`);

  // save, new, open
  what = 'save';
  ctrl(m, 'k'); key(m, 'KeyS'); type(m, 'letter'); key(m, 'Enter'); settle(m);
  assert(row(m, 23).includes('SAVED') && row(m, 0).includes('LETTER'), 'save: ' + row(m, 23) + ' / ' + row(m, 0));
  const idx = img.subarray(DOC_BASE * 512, DOC_BASE * 512 + 512);
  assert(String.fromCharCode(...idx.subarray(0, 4)) === 'DOCS' && idx[32] === 1, 'index on the SD');
  const len = idx[33] | (idx[34] << 8);
  const saved = String.fromCharCode(...img.subarray((DOC_BASE + 40) * 512, (DOC_BASE + 40) * 512 + len));
  const expect = PARA.replace(/a /gi, 'A ');
  assert(len === expect.length && saved === expect && String.fromCharCode(...idx.subarray(36, 42)) === 'LETTER', 'saved data');
  shot(m, 'saved');
  ctrl(m, 'k'); key(m, 'KeyN'); settle(m);
  assert(text(m) === '' && row(m, 0).includes('NO NAME'), 'new');
  type(m, 'short note');
  ctrl(m, 'k'); key(m, 'KeyA'); type(m, 'note'); key(m, 'Enter'); settle(m);
  ctrl(m, 'k'); key(m, 'KeyO'); settle(m);
  assert(row(m, 2).includes('LETTER') && row(m, 3).includes('NOTE'), 'open list\n' + screenText(m));
  shot(m, 'open');
  key(m, 'Enter'); settle(m);
  assert(text(m) === expect && cursor(m) === 0 && row(m, 0).includes('LETTER'), 'open: ' + text(m).slice(0, 30));
  console.log(`      save ${len} bytes in slot 1, ^KN, ^KA, ^KO list and open ok`);

  // a big document: 18000 characters written on the SD, then opened
  what = 'big';
  const words = PARA.split(' ');
  let big = '';
  for (let i = 0; big.length < 18000; i++) big += words[i % words.length] + (i % 37 === 36 ? '\n' : ' ');
  big = big.slice(0, 18000);
  for (let i = 0; i < 36; i++) img.fill(0, (DOC_BASE + 120 + i) * 512, (DOC_BASE + 121 + i) * 512);
  for (let i = 0; i < big.length; i++) img[(DOC_BASE + 120) * 512 + i] = big.charCodeAt(i) === 10 ? 13 : big.charCodeAt(i);
  const e = DOC_BASE * 512 + 3 * 32;
  img[e] = 1; img[e + 1] = big.length & 255; img[e + 2] = big.length >> 8;
  'BIG'.split('').forEach((c, i) => { img[e + 4 + i] = c.charCodeAt(0); });
  ctrl(m, 'k'); key(m, 'KeyO'); key(m, 'ArrowDown'); key(m, 'ArrowDown'); settle(m);
  worst = 0;
  const t0 = m.cpu.cycles;
  key(m, 'Enter'); settle(m);
  const openC = m.cpu.cycles - t0;
  assert(text(m) === big, 'big document loaded wrong');
  worst = 0; ctrl(m, 'q'); key(m, 'KeyC'); settle(m);
  const endC = worst;
  assert(cursor(m) === big.length, '^QC on the big document');
  worst = 0; key(m, 'PageUp'); settle(m);
  const pgC = worst;
  worst = 0; ctrl(m, 'q'); key(m, 'KeyR'); settle(m);
  const topC = worst;
  for (let i = 0; i < 300; i++) key(m, 'ArrowDown');
  settle(m);
  worst = 0; type(m, 'x');
  const midC = worst;
  const st = row(m, 0);
  shot(m, 'big');
  console.log(`      18000 characters: open ${(openC / 1e6).toFixed(2)} s, ^QC ${(endC / 1e6).toFixed(2)} s, PgUp ${(pgC / 1e6).toFixed(2)} s, ^QR ${(topC / 1e6).toFixed(2)} s, a key in the middle ${midC} cycles; status "${st.trim()}"`);

  // fast keys: arrows (E0 prefix) and letters with one frame between events
  what = 'fast';
  ctrl(m, 'q'); key(m, 'KeyC'); settle(m);
  const before = text(m).length;
  const k = kb(m);
  const seq = 'the quick brown fox';
  for (const ch of seq) {
    const code = ch === ' ' ? 'Space' : 'Key' + ch.toUpperCase();
    k.keyDown(code); k.keyUp(code);
  }
  for (let i = 0; i < 5; i++) { k.keyDown('ArrowLeft'); k.keyUp('ArrowLeft'); }
  k.keyDown('KeyZ'); k.keyUp('KeyZ');
  settle(m, 6000);
  const tail = text(m).slice(before);
  assert(tail === 'the quick browzn fox', 'fast keys: ' + JSON.stringify(tail));
  console.log('      ' + (seq.length + 6) + ' key events back to back (with arrows): none lost');

  // quit without saving: confirmation, then the BIOS menu
  what = 'quit';
  ctrl(m, 'k'); key(m, 'KeyQ'); settle(m);
  assert(row(m, 23).includes('ABANDON'), 'quit asks: ' + row(m, 23));
  key(m, 'KeyN'); settle(m);
  ctrl(m, 'k'); key(m, 'KeyQ'); settle(m); key(m, 'KeyY');
  runFrames(m, 120);
  assert(m.cpu.pc >= 0x8000, 'back to the BIOS');
  console.log('      ^KQ asks before abandoning the changes, then back to the BIOS menu');
}
