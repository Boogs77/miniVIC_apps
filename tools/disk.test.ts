// disk.test.ts - miniVIC DISK on the bo6502-emulator core with the BIOS KEYB/SD
import { loadApp, sdImage, Run, assert, DOC_BASE } from './harness';

function putDoc(img: Uint8Array, slot: number, type: number, name: string, data: number[]) {
  const ix = DOC_BASE * 512;
  if (img[ix] !== 0x44) { img.set([0x44, 0x4F, 0x43, 0x53, 1, 15], ix); }      // "DOCS"
  const e = ix + slot * 32;
  img.fill(0, e, e + 32);
  img[e] = type; img[e + 1] = data.length & 255; img[e + 2] = data.length >> 8;
  for (let i = 0; i < name.length; i++) img[e + 4 + i] = name.charCodeAt(i);
  img.set(data, (DOC_BASE + slot * 40) * 512);
}
const entry = (img: Uint8Array, slot: number) => {
  const e = DOC_BASE * 512 + slot * 32;
  return { type: img[e], len: img[e + 1] | (img[e + 2] << 8), name: String.fromCharCode(...img.subarray(e + 4, e + 16)).replace(/\0+$/, '') };
};

export default async function () {
  const names = ['write', 'calc', 'file', 'mon', 'desk', 'term', 'disk'];
  const apps = names.map(n => loadApp(n, n[0].toUpperCase() + n.slice(1)));
  const img = sdImage(apps);
  const text = 'Hello\rWorld\r';
  putDoc(img, 1, 1, 'HELLO', [...text].map(c => c.charCodeAt(0)));
  putDoc(img, 2, 4, 'PROG', [0x00, 0x30, 0xA9, 0x41, 0x60]);
  const r = new Run(apps[6], img, 7);
  assert(r.row(0).includes('SDSC V1') && /7 PROGS/.test(r.row(0)) && /2 DOCS/.test(r.row(0)), 'status: ' + r.row(0));
  assert(r.row(2).includes('WRITE - APP') && r.row(2).trimEnd().endsWith(String(apps[0].bin.length)) && r.row(8).includes('DISK - APP'),
    'programs\n' + r.screen());
  r.shot('programs');
  console.log(`      start ok, ${apps[6].bin.length} bytes; card SDSC V1, 7 programs with their lengths`);

  r.key('F3'); r.settle();
  assert(r.row(2).includes('HELLO') && r.row(2).includes('TEXT') && r.row(3).includes('PROG') && r.row(3).includes('CODE') && r.row(4).includes('(FREE)'),
    'documents\n' + r.screen());
  r.shot('documents');
  r.type('v');
  assert(r.row(0).startsWith('Hello') && r.row(1).startsWith('World'), 'view text\n' + r.screen());
  r.key('Escape'); r.settle();
  r.key('ArrowDown'); r.type('v');
  assert(r.row(0).startsWith('0000  00 30 A9 41 60'), 'view hex\n' + r.screen());
  r.key('Escape'); r.settle();
  console.log('      F3 documents, V as text and as hex ok');

  r.key('ArrowUp'); r.type('r'); r.type('greet'); r.key('Enter'); r.settle();
  assert(entry(img, 1).name === 'GREET', 'rename: ' + entry(img, 1).name);
  r.type('c'); r.type('copy1'); r.key('Enter'); r.settle();
  const c = entry(img, 3);
  const data = String.fromCharCode(...img.subarray((DOC_BASE + 3 * 40) * 512, (DOC_BASE + 3 * 40) * 512 + c.len));
  assert(c.type === 1 && c.name === 'COPY1' && data === text && r.row(23).includes('COPIED'), 'copy: ' + JSON.stringify(c));
  r.key('ArrowDown'); r.key('ArrowDown'); r.key('Delete'); r.settle(); r.key('KeyY'); r.settle();
  assert(entry(img, 3).type === 0 && r.row(4).includes('(FREE)'), 'delete');
  r.type('f'); r.key('KeyY'); r.settle();
  assert(entry(img, 1).type === 0 && entry(img, 2).type === 0 && /0 DOCS/.test(r.row(0)), 'format');
  console.log('      R rename, C copy (data checked), Del delete, F empty index ok');

  // run another program from the list
  r.key('F2'); r.settle();
  for (let i = 0; i < 3; i++) r.key('ArrowDown');
  r.key('Enter'); r.settle(); r.key('KeyY');
  for (let i = 0; i < 400 && !r.row(0).includes('MINIVIC MON'); i++) r.m.runFrame();
  assert(r.row(0).includes('MINIVIC MON') && /\[APP\] MON/.test(r.serialText()), 'MON started from DISK\n' + r.screen());
  console.log('      Enter on program 4 runs MON (the BIOS sends "[APP] MON") ok');
}
