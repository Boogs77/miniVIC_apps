// asm.test.ts - miniVIC ASM on the bo6502-emulator core with the BIOS KEYB/SD.
// The same source is assembled by vasm too: the bytes must be the same.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { loadApp, sdImage, Run, assert, DOC_BASE, ROOT } from './harness';

function putDoc(img: Uint8Array, slot: number, type: number, name: string, data: number[]) {
  const ix = DOC_BASE * 512;
  if (img[ix] !== 0x44) img.set([0x44, 0x4F, 0x43, 0x53, 1, 15], ix);
  const e = ix + slot * 32;
  img.fill(0, e, e + 32);
  img[e] = type; img[e + 1] = data.length & 255; img[e + 2] = data.length >> 8;
  for (let i = 0; i < name.length; i++) img[e + 4 + i] = name.charCodeAt(i);
  img.set(data, (DOC_BASE + slot * 40) * 512);
}
const SRC = [
  '; a test program for miniVIC ASM',
  'SCREEN = $0800',
  'COUNT  = 3',
  '        .ORG $3000',
  'START:  LDX #0',
  'LOOP    LDA MSG,X        ; forward symbol: absolute',
  '        BEQ DONE',
  '        STA $3100,X',
  '        STA $10,X',
  '        INX',
  '        CPX #COUNT+1',
  '        BNE LOOP',
  'DONE    LDA #<MSG',
  '        LDY #>MSG',
  '        JSR SUB',
  '        LDA SCREEN+2',
  '        ASL',
  '        INC A',
  '        RTS',
  'SUB     STA $10',
  '        RMB3 $10',
  '        BBS7 $10,SUB',
  '        LDA ($10),Y',
  '        LDA ($10,X)',
  '        LDA ($10)',
  '        JMP (TABLE,X)',
  '        BRA SUB',
  'TABLE   .WORD START, DONE',
  "MSG     .BYTE \"Hi\",13,0",
  '        .RES 2',
  "        .BYTE %1010, 'A', *-START, -1",
  '        .TEXT "END"',
];
const BAD = [
  '        .ORG $3000',
  '        LDA NOWHERE',
  '        LDA #$1234',
  '        STX $1234,X',
  'TWICE   NOP',
  'TWICE   NOP',
  '        BNE FAR',
  '        .RES 200',
  'FAR     NOP',
  '        FOO',
];

function vasmBytes(lines: string[]): number[] {
  const vasm = readFileSync(join(ROOT, 'vasm.path'), 'utf8').split(/\r?\n/)[0].trim();
  const dir = join(ROOT, 'tools', '.asmtest');
  mkdirSync(dir, { recursive: true });
  // vasm oldstyle: .RES -> .dsb, .TEXT -> .byte, "Hi" kept
  const src = lines.map(l => l.replace(/\.RES\b/, '.dsb').replace(/\.TEXT\b/, '.byte').replace(/^SCREEN = /, 'SCREEN = ').replace(/^COUNT  = /, 'COUNT = '));
  writeFileSync(join(dir, 't.asm'), src.join('\n') + '\n');
  const r = spawnSync(vasm, ['-Fbin', '-dotdir', '-wdc02', '-quiet', '-o', join(dir, 't.bin'), join(dir, 't.asm')], { encoding: 'utf8' });
  assert(r.status === 0, 'vasm: ' + r.stdout + r.stderr);
  return Array.from(readFileSync(join(dir, 't.bin')));
}

export default async function () {
  const names = ['write', 'calc', 'file', 'mon', 'desk', 'term', 'disk', 'asm'];
  const apps = names.map(n => loadApp(n, n[0].toUpperCase() + n.slice(1)));
  const img = sdImage(apps);
  const toBytes = (l: string[]) => [...(l.join('\r') + '\r')].map(c => c.charCodeAt(0));
  putDoc(img, 1, 1, 'PROG', toBytes(SRC));
  putDoc(img, 2, 1, 'BAD', toBytes(BAD));
  const expect = vasmBytes(SRC);
  const r = new Run(apps[7], img, 8);
  assert(r.screen().includes('ASSEMBLE WHICH TEXT') && r.row(2).includes('PROG'), 'start: the list\n' + r.screen());
  console.log(`      start ok, ${apps[7].bin.length} bytes`);

  r.key('Enter'); r.settle();
  const got = Array.from(r.m.ram.subarray(0x4000, 0x4000 + expect.length) as Uint8Array);
  const hex = (a: number[]) => a.map(v => v.toString(16).padStart(2, '0')).join(' ');
  const end = (0x3000 + expect.length - 1).toString(16).toUpperCase();
  assert(hex(got) === hex(expect) && r.screen().includes(`OK: $3000-$${end} ${expect.length} BYTES`),
    `bytes:\n ours ${hex(got)}\n vasm ${hex(expect)}\n` + r.screen());
  assert(r.screen().includes('8 SYMBOLS'), 'symbols\n' + r.screen());
  console.log(`      ${SRC.length} source lines assembled: ${expect.length} bytes, the same as vasm`);
  r.shot('ok');

  r.type('s'); r.key('Enter'); r.settle();
  const ix = DOC_BASE * 512;
  const k = [1, 2, 3, 4].find(i => img[ix + i * 32] === 4)!;
  const len = img[ix + k * 32 + 1] | (img[ix + k * 32 + 2] << 8);
  const saved = Array.from(img.subarray((DOC_BASE + k * 40) * 512, (DOC_BASE + k * 40) * 512 + len));
  assert(k && len === expect.length + 2 && saved[0] === 0x00 && saved[1] === 0x30 && hex(saved.slice(2)) === hex(expect) && r.screen().includes('SAVED'),
    'saved code: ' + hex(saved));
  console.log('      S saves it as CODE (address + bytes) for MON');

  r.type('a'); r.settle();
  r.key('ArrowDown'); r.key('Enter'); r.settle();
  const s = r.screen();
  const want = ['LINE 2: UNDEFINED SYMBOL', 'LINE 3: VALUE OVER $FF', 'LINE 4: ADDRESSING MODE', 'LINE 6: DEFINED TWICE',
    'LINE 7: BRANCH TOO FAR', 'LINE 10: SYNTAX', '6 ERRORS'];
  for (const w of want) assert(s.includes(w), `"${w}" missing\n` + s);
  r.shot('errors');
  console.log('      a source with 6 errors: each one with its line and message');
  r.key('KeyQ');                                      // (no settle: ASM is gone)
  for (let i = 0; i < 120; i++) r.m.runFrame();
  assert(r.m.cpu.pc >= 0x8000, 'back to the BIOS');
  console.log('      Q back to the BIOS menu');
}
