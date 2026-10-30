// harness.ts - shared test helpers: the bo6502-emulator core with the BIOS KEYB/SD, an SD image
// with the applications, PS/2 typing, waiting for the application to be idle, screenshots
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { buildMachine, defaultConfig } from 'EMU/src/machines/profiles';
import { buildSdImage } from 'EMU/src/machines/sdimage';
import { SdCardBoard, KeyboardBoard, SerialBoard } from 'EMU/src/boards/Boards';
import { screenText, runFrames, assert, writePng } from 'EMU/tests/helpers';
import { TMS_PALETTE, SCREEN_W, SCREEN_H } from 'EMU/src/devices/TMS9918A';

declare const __ROOT__: string;
export const ROOT = __ROOT__;
export { screenText, runFrames, assert };
export const DOC_BASE = 16384;

export interface App { name: string; bin: Uint8Array; sym: Record<string, number>; serial: string }

/** bin/<name>.bin (or the file in the env variable) and the symbols of its listing */
export function loadApp(name: string, menuName: string, env?: string): App {
  const f = (env && process.env[env]) || join(ROOT, 'bin', name + '.bin');
  const bin = new Uint8Array(readFileSync(f));
  const sym: Record<string, number> = {};
  const lst = readFileSync(f.replace(/\.bin$/, '.lst'), 'latin1');
  const part = lst.slice(lst.indexOf('Symbols by value:'));
  for (const m of part.matchAll(/^([0-9A-F]{4,8}) (\S+)/gm)) sym[m[2]] = parseInt(m[1], 16);
  return { name, bin, sym, serial: menuName };
}

/** SD image (9 MB) with the apps as programs 1, 2, ... (type APP in the directory) */
export function sdImage(apps: App[]): Uint8Array {
  const base = buildSdImage(apps.map(a => ({ name: a.serial.toUpperCase() + ' - APP', data: a.bin, load: 0x0FD0, entry: 0x1000, run: true })));
  const img = new Uint8Array(9 * 1024 * 1024);
  img.set(base);
  apps.forEach((a, i) => { img[16 + i * 8 + 6] = 2; img[16 + i * 8 + 7] = a.serial.length; });
  return img;
}

/** a machine running one application, with idle detection and key timings */
export class Run {
  m: any;
  idleHits = 0;
  inKey = -1;
  worst = 0;
  serial: number[] = [];
  constructor(public app: App, img: Uint8Array, slot: number, page = 1) {
    const m = this.m = buildMachine(defaultConfig('minivic'));
    m.loadRom(new Uint8Array(readFileSync(process.env.BIOS_ROM!)));
    (m.board<SdCardBoard>('sdcard')! as any).card.insert(img);
    m.powerOn();
    const s = app.sym;
    m.breakpoint = (pc: number) => {
      if (pc === s.WAITKEY) this.idleHits++;
      if (pc === s.DOKEY && this.inKey < 0) this.inKey = m.cpu.cycles;
      if (pc === s.IDLE) {
        this.idleHits++;
        if (this.inKey >= 0) { this.worst = Math.max(this.worst, m.cpu.cycles - this.inKey); this.inKey = -1; }
      }
      return false;
    };
    runFrames(m, 90);
    m.board<SerialBoard>('serial')!.acia.onTransmit = (b: number) => this.serial.push(b);
    this.key('Digit3'); runFrames(m, 150);
    assert(screenText(m).includes('SD PROGRAMS MENU'), 'SD menu not found\n' + screenText(m));
    for (let p = 1; p < page; p++) { this.key('KeyD'); runFrames(m, 150); }   // next menu page
    this.serial.length = 0;
    this.key('Digit' + slot);
    for (let f = 0; f < 1500 && this.idleHits === 0; f++) runFrames(m, 1);
    assert(this.idleHits > 0, app.name + ' did not start');
    this.settle();
  }
  get kb() { return this.m.board<KeyboardBoard>('keyboard')!.keyboard; }
  kbIdle() { const k = this.kb as any; return k.queue.length === 0 && k.packet.length === 0; }
  /** waits until the application loops waiting for a key */
  settle(max = 3000) {
    for (let f = 0; f < max; f++) {
      const h = this.idleHits;
      runFrames(this.m, 1);
      if (this.idleHits - h > 5 && this.kbIdle()) return f;
    }
    throw new Error(this.app.name + ' does not go back to idle');
  }
  key(code: string, mods: string[] = [], hold = 1) {
    const k = this.kb;
    for (const x of mods) k.keyDown(x);
    k.keyDown(code); runFrames(this.m, hold); k.keyUp(code);
    for (const x of mods) k.keyUp(x);
    runFrames(this.m, 1);
  }
  ctrl(letter: string) { this.key('Key' + letter.toUpperCase(), ['ControlLeft']); }
  type(s: string, wait = true) {
    for (const ch of s) {
      if (/[a-z]/.test(ch)) this.key('Key' + ch.toUpperCase());
      else if (/[A-Z]/.test(ch)) this.key('Key' + ch, ['ShiftLeft']);
      else if (/[0-9]/.test(ch)) this.key('Digit' + ch);
      else if (PLAIN[ch]) this.key(PLAIN[ch]);
      else if (SHIFTED[ch]) this.key(SHIFTED[ch], ['ShiftLeft']);
      else throw new Error('no key for ' + JSON.stringify(ch));
    }
    if (wait) this.settle();
  }
  /** screen row without the inverse bit */
  row(r: number): string {
    const v = this.m.vdu!.vdp.vram;
    let s = '';
    for (let c = 0; c < 40; c++) s += String.fromCharCode(v[0x0800 + r * 40 + c] & 0x7F);
    return s;
  }
  screen(): string { return Array.from({ length: 24 }, (_, r) => this.row(r)).join('\n'); }
  shot(name: string) {
    runFrames(this.m, 2);                     // (the frame shown is the last one finished)
    const vdp = this.m.vdu!.vdp;
    const dir = join(ROOT, 'screenshots');
    mkdirSync(dir, { recursive: true });
    // twice the size, square pixels kept sharp
    const f = writePng(this.app.name + '_' + name, SCREEN_W * 2, SCREEN_H * 2,
      (x, y) => TMS_PALETTE[vdp.frame[(y >> 1) * SCREEN_W + (x >> 1)]]);
    writeFileSync(join(dir, this.app.name + '_' + name + '.png'), readFileSync(f));
  }
  serialText() { return String.fromCharCode(...this.serial); }
}

const SHIFTED: Record<string, string> = {
  '!': 'Digit1', '@': 'Digit2', '#': 'Digit3', '$': 'Digit4', '%': 'Digit5', '^': 'Digit6', '&': 'Digit7',
  '*': 'Digit8', '(': 'Digit9', ')': 'Digit0', ':': 'Semicolon', '"': 'Quote', '?': 'Slash', '_': 'Minus', '+': 'Equal',
  '>': 'Period', '<': 'Comma',
};
const PLAIN: Record<string, string> = {
  ' ': 'Space', '.': 'Period', ',': 'Comma', ';': 'Semicolon', "'": 'Quote', '-': 'Minus', '/': 'Slash', '=': 'Equal',
  '\n': 'Enter',
};
