// file.test.ts - miniVIC FILE on the bo6502-emulator core with the BIOS KEYB/SD
import { loadApp, sdImage, Run, assert, DOC_BASE } from './harness';

const ORDER = 0x3000, DATA = 0x3100;
function cards(r: Run): string[][] {
  const ram = r.m.ram, nf = ram[0x50], rs = ram[0x51], n = ram[0x52], out: string[][] = [];
  for (let i = 0; i < n; i++) {
    const p = DATA + ram[ORDER + i] * rs, f: string[] = [];
    for (let k = 0; k < nf; k++) {
      const off = ram[0x0268 + k], w = ram[0x0260 + k];
      f.push(String.fromCharCode(...ram.subarray(p + off, p + off + w)).trimEnd());
    }
    out.push(f);
  }
  return out;
}
const cur = (r: Run) => r.m.ram[0x53];
function card(r: Run, fields: string[]) {             // types the fields of the card shown, from the first
  for (const f of fields) { if (f) r.type(f, false); r.key('ArrowDown'); }
  r.settle();
}

export default async function () {
  const apps = [loadApp('write', 'Write'), loadApp('calc', 'Calc'), loadApp('file', 'File')];
  const img = sdImage(apps);
  const r = new Run(apps[2], img, 3);
  assert(/\[APP\] FILE/.test(r.serialText()), 'serial line: ' + r.serialText());
  assert(r.row(2).startsWith('NAME      : ') && r.row(14).startsWith('NOTES     : '), 'address book form\n' + r.screen());
  console.log(`      start ok, ${apps[2].bin.length} bytes, ${r.m.ram[0x57]} cards fit (record ${r.m.ram[0x51]} bytes)`);

  card(r, ['Mario Rossi', 'Via Roma 1', 'Milano', '02 1234']);
  r.key('F3'); r.settle();
  card(r, ['Anna Bianchi', '', 'Roma']);
  r.key('F3'); r.settle();
  card(r, ['Carlo Verdi', 'Corso Francia 7', 'Torino', '011 555']);
  let c = cards(r);
  assert(c.length === 3 && c[0][0] === 'Mario Rossi' && c[0][2] === 'Milano' && c[1][2] === 'Roma' && c[2][1] === 'Corso Francia 7',
    'cards: ' + JSON.stringify(c));
  r.shot('card');
  // sort by NAME (the cursor field: back to the first one)
  r.key('Home'); r.ctrl('t'); r.settle();
  while (r.m.ram[0x54] !== 0) r.key('ArrowUp');
  r.key('F6'); r.settle();
  c = cards(r);
  assert(c.map(x => x[0]).join(',') === 'Anna Bianchi,Carlo Verdi,Mario Rossi', 'sorted: ' + c.map(x => x[0]));
  // sort by CITY
  r.key('ArrowDown'); r.key('ArrowDown'); r.key('F6'); r.settle();
  assert(cards(r).map(x => x[2]).join(',') === 'Milano,Roma,Torino', 'sorted by city');
  // find (any case, any field)
  r.key('F4'); r.type('FRANCIA', false); r.key('Enter'); r.settle();
  assert(cards(r)[cur(r)][0] === 'Carlo Verdi', 'find: card ' + cur(r));
  r.key('F4'); for (let i = 0; i < 7; i++) r.key('Backspace');
  r.type('ro', false); r.key('Enter'); r.settle();
  const first = cards(r)[cur(r)][0];
  r.key('F5'); r.settle();
  const second = cards(r)[cur(r)][0];
  assert(first === 'Mario Rossi' && second === 'Anna Bianchi', `find again: ${first} / ${second}`);
  console.log('      3 cards typed, F6 sort by name and by city, F4 find in any field, F5 again ok');
  // list, then delete a card
  r.key('F2'); r.settle();
  assert(r.row(1).includes('NAME') && r.row(2).includes('Mario Rossi') && r.row(4).includes('Carlo Verdi'), 'list\n' + r.screen());
  r.shot('list');
  r.key('ArrowDown'); r.key('Enter'); r.settle();
  assert(cards(r)[cur(r)][0] === 'Carlo Verdi', 'list Enter: card ' + cur(r));
  r.key('F8'); r.settle(); r.key('KeyY'); r.settle();
  c = cards(r);
  assert(c.length === 2 && c.map(x => x[0]).join(',') === 'Mario Rossi,Anna Bianchi', 'delete: ' + c.map(x => x[0]));
  console.log('      F2 list, Enter on a row, F8 delete ok');
  // edit inside a field: Backspace, Del, overwrite
  r.ctrl('t'); r.settle();
  while (r.m.ram[0x54] !== 0) r.key('ArrowUp');
  r.key('End'); r.key('Backspace'); r.key('Backspace'); r.type('i', false);
  r.key('Home'); r.key('Delete'); r.type('X'); r.settle();
  assert(cards(r)[0][0] === 'Xrio Rosi', 'field edit: ' + cards(r)[0][0]);
  // save, new form, open again
  r.ctrl('k'); r.key('KeyS'); r.type('friends', false); r.key('Enter'); r.settle();
  assert(r.row(23).includes('SAVED'), 'save: ' + r.row(23));
  const idx = img.subarray(DOC_BASE * 512, DOC_BASE * 512 + 512);
  const k = [1, 2, 3].find(i => idx[i * 32] === 3)!;
  assert(k && String.fromCharCode(...idx.subarray(k * 32 + 4, k * 32 + 11)) === 'FRIENDS', 'index entry');
  r.ctrl('k'); r.key('KeyN'); r.settle();
  r.type('title', false); r.key('Enter'); r.type('20', false); r.key('Enter');
  r.type('author', false); r.key('Enter'); r.type('16', false); r.key('Enter');
  r.type('year', false); r.key('Enter'); r.type('4', false); r.key('Enter');
  r.key('Enter'); r.settle();
  assert(r.m.ram[0x50] === 3 && r.m.ram[0x51] === 40 && r.row(2).startsWith('TITLE     : ') && r.row(6).startsWith('YEAR'), 'new form\n' + r.screen());
  card(r, ['The Hobbit', 'Tolkien', '1937']);
  r.shot('newform');
  r.ctrl('k'); r.key('KeyO'); r.settle();
  assert(r.row(23).includes('ABANDON') || r.screen().includes('OPEN CARD FILE'), 'open asks or lists');
  if (r.row(23).includes('ABANDON')) { r.key('KeyY'); r.settle(); }
  // the list of documents: the card file is the first one
  r.key('Enter'); r.settle();
  if (r.row(23).includes('ABANDON')) { r.key('KeyY'); r.settle(); }
  c = cards(r);
  assert(r.m.ram[0x50] === 7 && c.length === 2 && c[0][0] === 'Xrio Rosi' && c[1][2] === 'Roma', 'open: ' + JSON.stringify(c));
  console.log('      ^KS save (type 3), ^KN new form of 3 fields, ^KO open the old file with its form ok');
  r.ctrl('k'); r.key('KeyQ');
  for (let i = 0; i < 120; i++) r.m.runFrame();
  assert(r.m.cpu.pc >= 0x8000, 'back to the BIOS');
  console.log('      ^KQ back to the BIOS menu');
}
