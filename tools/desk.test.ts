// desk.test.ts - miniVIC DESK on the bo6502-emulator core with the BIOS KEYB/SD
import { loadApp, sdImage, Run, assert } from './harness';

const acc = (r: Run) => (r.m.ram[0x220] | (r.m.ram[0x221] << 8) | (r.m.ram[0x222] << 16) | (r.m.ram[0x223] << 24)) / 100;
const memv = (r: Run) => (r.m.ram[0x224] | (r.m.ram[0x225] << 8) | (r.m.ram[0x226] << 16) | (r.m.ram[0x227] << 24)) / 100;

export default async function () {
  const names: [string, string][] = [['write', 'Write'], ['calc', 'Calc'], ['file', 'File'], ['mon', 'Mon'], ['desk', 'Desk']];
  const apps = names.map(([f, n]) => loadApp(f, n));
  const r = new Run(apps[4], sdImage(apps), 5);
  const s = apps[4].sym;
  assert(/\[APP\] DESK/.test(r.serialText()) && r.row(0).includes('CALCULATOR'), 'start\n' + r.screen());
  console.log(`      start ok, ${apps[4].bin.length} bytes`);

  // calculator
  r.type('12.5+7.5=');
  assert(acc(r) === 20, '12.5+7.5 = ' + acc(r));
  r.type('*3=');
  assert(acc(r) === 60, '*3 = ' + acc(r));
  r.type('/7=');
  assert(acc(r) === 8.57, '/7 = ' + acc(r));
  r.type('/0=');
  assert(r.m.ram[s.CERR] === 1 && r.row(20).includes('ERROR'), 'division by zero\n' + r.screen());
  r.key('Escape'); r.settle();
  r.type('100m50n');
  assert(memv(r) === 50, 'M+ 100 M- 50 = ' + memv(r));
  r.type('r+1=');
  assert(acc(r) === 51, 'MR + 1 = ' + acc(r));
  r.key('Escape'); r.type('5s=');
  assert(acc(r) === -5, 'sign: ' + acc(r));
  r.type('k');
  assert(memv(r) === 0 && r.row(20).includes('-5'), 'MC and the display');
  r.shot('calculator');
  console.log('      calculator: + * / with 2 decimals, division by zero, M+ M- MR MC, sign ok');

  // calendar
  r.key('F3'); r.settle();
  const grid = () => r.screen().split('\n').slice(7, 19).join('\n');
  assert(r.screen().includes('JANUARY 2026') && r.row(7).slice(18, 21) === '  1', 'January 2026 starts on Thursday\n' + r.screen());
  for (let i = 0; i < 9; i++) r.key('ArrowRight');
  r.settle();
  assert(r.screen().includes('OCTOBER 2026') && r.row(7).slice(18, 21) === '  1' && grid().includes('31'), 'October 2026\n' + r.screen());
  r.shot('calendar');
  r.key('ArrowUp'); r.key('ArrowUp'); r.settle();
  for (let i = 0; i < 8; i++) r.key('ArrowLeft');
  r.settle();
  assert(r.screen().includes('FEBRUARY 2024') && grid().includes('29') && r.row(7).slice(18, 21) === '  1', 'February 2024 (leap year)\n' + r.screen());
  for (let i = 0; i < 76; i++) r.key('ArrowDown');
  r.settle();
  assert(r.screen().includes('FEBRUARY 2100') && grid().includes('28') && !grid().includes('29'), 'February 2100 (not a leap year)\n' + r.screen());
  console.log('      calendar: weekdays of January and October 2026, February 2024 (29 days), 2100 (28) ok');

  // clock: set 30 October 2026 23:59:50, 15 seconds later it is Saturday 31 October 00:00:05
  r.key('F4'); r.settle();
  r.type('s'); r.type('2026 10 30'); r.key('Enter'); r.settle();
  r.type('23 59 50'); r.key('Enter'); r.settle();
  for (let i = 0; i < 15 * 60; i++) r.m.runFrame();
  r.settle();
  const t = [s.HH, s.MM, s.SS, s.DDA, s.DMO].map(a => r.m.ram[a]);
  assert(t.join(' ') === '0 0 5 31 10' && r.screen().includes('SATURDAY 31 OCTOBER 2026'), 'clock after 15 s: ' + t.join(' ') + '\n' + r.screen());
  r.shot('clock');
  // alarm at 00:01
  r.type('a'); r.type('00 01'); r.key('Enter'); r.settle();
  for (let i = 0; i < 56 * 60; i++) r.m.runFrame();
  r.settle();
  assert(r.m.ram[s.RING] === 1 && r.row(23).includes('ALARM'), 'alarm rings\n' + r.screen());
  r.key('Space'); r.settle();
  assert(r.m.ram[s.RING] === 0, 'a key stops the alarm');
  console.log('      clock: set, 15 s across midnight to SATURDAY 31 OCTOBER, alarm at 00:01 rings and stops ok');

  r.key('KeyQ');
  for (let i = 0; i < 120; i++) r.m.runFrame();
  assert(r.m.cpu.pc >= 0x8000, 'back to the BIOS');
  console.log('      Q back to the BIOS menu');
}
