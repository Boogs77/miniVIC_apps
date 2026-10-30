// mon.test.ts - miniVIC MON on the bo6502-emulator core with the BIOS KEYB/SD
import { loadApp, sdImage, Run, assert } from './harness';

function cmd(r: Run, line: string) { r.type(line, false); r.key('Enter'); r.settle(); }
const mem = (r: Run, a: number, n: number) => Array.from(r.m.ram.subarray(a, a + n) as Uint8Array);
const hex = (a: number[]) => a.map(v => v.toString(16).padStart(2, '0')).join(' ');

export default async function () {
  const apps = [loadApp('write', 'Write'), loadApp('calc', 'Calc'), loadApp('file', 'File'), loadApp('mon', 'Mon')];
  const img = sdImage(apps);
  const r = new Run(apps[3], img, 4);
  assert(/\[APP\] MON/.test(r.serialText()) && r.row(0).includes('MINIVIC MON'), 'start\n' + r.screen());
  console.log(`      start ok, ${apps[3].bin.length} bytes`);

  // assemble a program, one line after the other ("A next" is offered each time)
  const prog = ['lda #$41', 'sta $3100', 'ldx #$05', 'inx', 'txa', 'ldy #$07', 'rts'];
  r.type('a 3000 ', false);
  for (const p of prog) cmd(r, p);
  cmd(r, '');
  assert(hex(mem(r, 0x3000, 12)) === 'a9 41 8d 00 31 a2 05 e8 8a a0 07 60', 'program: ' + hex(mem(r, 0x3000, 12)));
  cmd(r, 'g 3000');
  assert(r.m.ram[0x3100] === 0x41 && /A=06 X=06 Y=07/.test(r.screen()), 'G and registers\n' + r.screen());
  console.log('      A assembles 7 lines (next address offered), G runs them: A=06 X=06 Y=07');

  // every addressing mode through A, then D shows them back
  const modes: [string, string, string][] = [
    ['lda ($12),y', 'b1 12', 'LDA ($12),Y'], ['lda ($12,x)', 'a1 12', 'LDA ($12,X)'], ['lda ($40)', 'b2 40', 'LDA ($40)'],
    ['jmp ($1234,x)', '7c 34 12', 'JMP ($1234,X)'], ['jmp ($1234)', '6c 34 12', 'JMP ($1234)'],
    ['stz $1234,x', '9e 34 12', 'STZ $1234,X'], ['stx $12,y', '96 12', 'STX $12,Y'], ['ldx $1234,y', 'be 34 12', 'LDX $1234,Y'],
    ['asl', '0a', 'ASL A'], ['inc a', '1a', 'INC A'], ['rmb5 $20', '57 20', 'RMB5 $20'], ['bbr3 $12,$3200', '3f 12 fd', 'BBR3 $12,$3200'],
    ['bne $3200', 'd0 fe', 'BNE $3200'], ['bra $31f0', '80 ee', 'BRA $31F0'], ['wai', 'cb', 'WAI'], ['bit #$80', '89 80', 'BIT #$80'],
    ['lda $0012', 'ad 12 00', 'LDA $0012'],
  ];
  for (const [src, bytes, dis] of modes) {
    cmd(r, 'a 3200 ' + src);
    cmd(r, '');
    const n = bytes.split(' ').length;
    assert(hex(mem(r, 0x3200, n)) === bytes, `A ${src}: ${hex(mem(r, 0x3200, n))} expected ${bytes}`);
    cmd(r, 'd 3200 3200');
    const line = r.screen().split('\n').reverse().find(l => l.startsWith('3200'))!;
    assert(line && line.slice(16).trim() === dis, `D ${src}: "${line}" expected ${dis}`);
  }
  cmd(r, 'a 3200 lda #$1234');
  assert(r.screen().includes('  ?'), 'a bad operand is an error');
  const before = r.m.ram[0x3200];
  cmd(r, 'a 3200 bne $4000');
  const shown = r.screen().split('\n').filter(l => l.trim());
  assert(shown[shown.length - 2].includes('?') && r.m.ram[0x3200] === before, 'a branch out of range is an error');
  console.log(`      A and D agree on ${modes.length} addressing modes (65C02, RMB/BBR, branches); bad operand and far branch rejected`);
  r.shot('disasm');

  // memory commands
  cmd(r, ': 3100 01 02 03');
  cmd(r, 'm 3100 3107');
  assert(r.screen().includes(':3100 01 02 03 00'), 'M after :\n' + r.screen());
  cmd(r, 'f 3200 320f aa');
  assert(mem(r, 0x3200, 16).every(v => v === 0xAA) && r.m.ram[0x3210] !== 0xAA, 'F');
  cmd(r, ': 3200 01 02 03 04');
  cmd(r, 't 3200 3203 3201');
  assert(hex(mem(r, 0x3200, 5)) === '01 01 02 03 04', 'T overlapping: ' + hex(mem(r, 0x3200, 5)));
  cmd(r, 'h 3000 3100 a9 41');
  assert(r.screen().split('\n').some(l => l.trim() === '3000'), 'H\n' + r.screen());
  console.log('      :, M, F, T (overlapping), H ok');

  // save to the SD, wipe, load back (and at another address)
  cmd(r, 's prog 3000 300b');
  assert(r.screen().includes('SAVED'), 'S\n' + r.screen());
  cmd(r, 'f 3000 300b 00');
  cmd(r, 'l prog');
  assert(hex(mem(r, 0x3000, 12)) === 'a9 41 8d 00 31 a2 05 e8 8a a0 07 60' && r.screen().includes('3000-300B'), 'L\n' + r.screen());
  cmd(r, 'l prog 4000');
  assert(hex(mem(r, 0x4000, 3)) === 'a9 41 8d', 'L at another address');
  console.log('      S to the SD (type 4), L back, L at another address ok');
  r.shot('memory');

  r.type('x', false); r.key('Enter');                // (no settle: the monitor is gone)
  for (let i = 0; i < 120; i++) r.m.runFrame();
  assert(r.m.cpu.pc >= 0x8000, 'back to the BIOS');
  console.log('      X back to the BIOS menu');
}
