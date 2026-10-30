// calc.test.ts - miniVIC CALC on the bo6502-emulator core with the BIOS KEYB/SD
import { loadApp, sdImage, Run, assert, DOC_BASE } from './harness';

const TABLE = 0x8000 - 26 * 99 * 2;

function cell(r: Run, name: string): { type: number; v: number; text: string } | null {
  const col = name.charCodeAt(0) - 65, row = parseInt(name.slice(1), 10) - 1;
  const ram = r.m.ram, t = TABLE + 2 * (row * 26 + col);
  const p = ram[t] | (ram[t + 1] << 8);
  if (!p) return null;
  const v = (ram[p + 4] | (ram[p + 5] << 8) | (ram[p + 6] << 16) | (ram[p + 7] << 24));
  let text = '';
  for (let a = p + 8; ram[a]; a++) text += String.fromCharCode(ram[a]);
  return { type: ram[p + 3], v: v / 100, text };
}
function expectVal(r: Run, name: string, v: number) {
  const c = cell(r, name);
  assert(c && !(c.type & 0x80) && Math.abs(c.v - v) < 0.001, `${name} = ${c ? (c.type & 0x80 ? 'ERROR' : c.v) : 'empty'}, expected ${v} (${c && c.text})`);
}
function enter(r: Run, entries: string[], move = 'ArrowDown') {
  for (const e of entries) { r.type(e, false); r.key(move); r.settle(); }
}
function goto(r: Run, name: string) { r.type('>', false); r.type(name, false); r.key('Enter'); r.settle(); }
function slash(r: Run, letter: string) { r.type('/', false); r.key('Key' + letter); r.settle(); }

export default async function () {
  const write = loadApp('write', 'Write');
  const calc = loadApp('calc', 'Calc');
  const img = sdImage([write, calc]);
  const r = new Run(calc, img, 2);
  assert(/\[APP\] CALC/.test(r.serialText()), 'serial line: ' + r.serialText());
  assert(r.row(0).includes('A1') && r.row(2).includes('A') && r.row(3).startsWith(' 1'), 'start screen\n' + r.screen());
  console.log(`      start ok, ${calc.bin.length} bytes, heap from $${(calc.sym.HEAP0 ?? 0).toString(16)}`);
  r.shot('start');

  // numbers, formulas, functions
  enter(r, ['10', '20.5', '-3', '@SUM(A1:A3)']);
  expectVal(r, 'A4', 27.5);
  goto(r, 'B1');
  enter(r, ['+A1*2', '+B1/3', '(A1+A2)*2', '@AVG(A1:A3)']);
  expectVal(r, 'B1', 20); expectVal(r, 'B2', 6.66); expectVal(r, 'B3', 61); expectVal(r, 'B4', 9.16);
  goto(r, 'C1');
  enter(r, ['@MAX(A1:B3)', '@MIN(A1...B3)', '@COUNT(A1:B3)', '1/0', '@SUM(A1,B1,@MAX(A2:A3),5)', '@ABS(A3)*@INT(B2)']);
  expectVal(r, 'C1', 61); expectVal(r, 'C2', -3); expectVal(r, 'C3', 6);
  assert((cell(r, 'C4')!.type & 0x80) !== 0, 'C4 1/0 must be an error');
  expectVal(r, 'C5', 10 + 20 + 20.5 + 5); expectVal(r, 'C6', 18);
  goto(r, 'D1');
  enter(r, ['Total', '"123', 'net 2026']);
  const d2 = cell(r, 'D2');
  assert(cell(r, 'D1')!.type === 1 && d2!.type === 1 && d2!.text === '123', 'labels');
  assert(r.row(3).includes('Total') && r.row(4).includes('123'), 'labels on the screen\n' + r.screen());
  // forward reference: worked out by the second pass
  goto(r, 'A6');
  enter(r, ['+A7*2', '5']);
  expectVal(r, 'A6', 10);
  // the value changes when a cell it uses changes
  goto(r, 'A1');
  r.worst = 0;
  enter(r, ['100']);
  expectVal(r, 'A4', 117.5); expectVal(r, 'B1', 200); expectVal(r, 'C1', 241);
  console.log(`      numbers, + - * /, ( ), @SUM @AVG @MIN @MAX @COUNT @ABS @INT, error, labels, forward reference ok; an entry with recalculation ${r.worst} cycles (${(r.worst / 1e6).toFixed(2)} s)`);
  r.shot('formulas');

  // replicate: relative and $ references, a block
  goto(r, 'E1');
  enter(r, ['+A1*10'], 'Enter');
  slash(r, 'R'); r.key('Enter'); r.type('E2:E3', false); r.key('Enter'); r.settle();
  expectVal(r, 'E2', 205); expectVal(r, 'E3', -30);
  assert(cell(r, 'E3')!.text === '+A3*10', 'E3 text ' + cell(r, 'E3')!.text);
  goto(r, 'F1');
  enter(r, ['+$A$1+A2'], 'Enter');
  slash(r, 'R'); r.key('Enter'); r.type('F2', false); r.key('Enter'); r.settle();
  assert(cell(r, 'F2')!.text === '+$A$1+A3', 'F2 text ' + cell(r, 'F2')!.text);
  expectVal(r, 'F2', 97);
  slash(r, 'R'); for (let i = 0; i < 4; i++) r.key('Backspace');
  r.type('A1:B3', false); r.key('Enter'); r.type('G2', false); r.key('Enter'); r.settle();
  expectVal(r, 'G2', 100); expectVal(r, 'G4', -3); expectVal(r, 'H2', 200); expectVal(r, 'H4', 241);
  assert(cell(r, 'H3')!.text === '+H2/3', 'H3 text ' + cell(r, 'H3')!.text);
  // an overlapping block moved down by one row: copied backwards
  slash(r, 'R'); for (let i = 0; i < 4; i++) r.key('Backspace');
  r.type('G2:G4', false); r.key('Enter'); r.type('G3', false); r.key('Enter'); r.settle();
  expectVal(r, 'G3', 100); expectVal(r, 'G4', 20.5); expectVal(r, 'G5', -3);
  console.log('      /R relative, $A$1 absolute, block, overlapping block ok');

  // width and go to
  slash(r, 'W'); r.type('6', false); r.key('Enter'); r.settle();
  assert(r.m.ram[calc.sym.NVIS] === 6, 'width 6 -> 6 columns, got ' + r.m.ram[calc.sym.NVIS]);
  goto(r, 'Z99');
  assert(r.m.ram[calc.sym.CX] === 25 && r.m.ram[calc.sym.CY] === 98, 'go to Z99');
  enter(r, ['@SUM(A1:B4)'], 'Enter');
  expectVal(r, 'Z99', 100 + 20.5 - 3 + 117.5 + 200 + 66.66 + 241 + 39.16);
  r.shot('z99');
  r.key('Home'); r.settle();
  r.shot('width6');
  console.log('      /W 6 columns, > Z99, @SUM over a range ok');

  // save, clear, load
  slash(r, 'S'); r.type('budget', false); r.key('Enter'); r.settle();
  assert(r.row(23).includes('SAVED'), 'save: ' + r.row(23));
  const idx = img.subarray(DOC_BASE * 512, DOC_BASE * 512 + 512);
  const k = [1, 2, 3].find(i => idx[i * 32] === 2)!;
  const len = idx[k * 32 + 1] | (idx[k * 32 + 2] << 8);
  const txt = String.fromCharCode(...img.subarray((DOC_BASE + k * 40) * 512, (DOC_BASE + k * 40) * 512 + len));
  assert(txt.startsWith('/W6\rA1 100\rB1 +A1*2\r') && txt.includes('D2 "123\r'), 'saved text: ' + JSON.stringify(txt.slice(0, 60)));
  const before = ['A4', 'B2', 'C5', 'E3', 'F2', 'H3', 'Z99'].map(n => cell(r, n)!.v);
  slash(r, 'C');                              // saved: no question
  assert(!r.row(23).includes('ABANDON'), '/C after a save must not ask');
  assert(cell(r, 'A1') === null && r.m.ram[calc.sym.NVIS] === 4, 'clear');
  slash(r, 'L');
  r.key('Enter'); r.settle();
  const after = ['A4', 'B2', 'C5', 'E3', 'F2', 'H3', 'Z99'].map(n => cell(r, n)!.v);
  assert(JSON.stringify(before) === JSON.stringify(after) && r.m.ram[calc.sym.NVIS] === 6 && r.row(0).length,
    'load: ' + JSON.stringify(before) + ' / ' + JSON.stringify(after));
  console.log(`      /S ${len} bytes as text, /C, /L back with the same values ok`);
  r.shot('loaded');

  // F2 edit, Del, quit
  goto(r, 'A1');
  r.key('F2'); r.key('Backspace'); r.key('Backspace'); r.type('5', false); r.key('Enter'); r.settle();
  expectVal(r, 'A1', 15);
  r.key('Delete'); r.settle();
  assert(cell(r, 'A1') === null, 'Del blanks');
  expectVal(r, 'A4', 17.5);
  slash(r, 'Q'); r.key('KeyY');
  for (let i = 0; i < 120; i++) r.m.runFrame();
  assert(r.m.cpu.pc >= 0x8000, 'back to the BIOS');
  console.log('      F2 edit, Del, /Q back to the BIOS menu ok');
}
