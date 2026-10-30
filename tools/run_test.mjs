// run_test.mjs - bundles a test (tools/<name>.test.ts) against the bo6502-emulator sources and runs it
//   node tools/run_test.mjs write          tests bin/write.bin with the BIOS KEYB/SD
//   BIOS_ROM=<file.bin> node tools/run_test.mjs write
// The BIOS KEYB/SD binary comes from BIOS_ROM or from the first line of the file bios.path (not in git).
import { createRequire } from 'node:module';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { existsSync, readFileSync } from 'node:fs';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..');
const EMU = join(root, '..', 'bo6502-emulator');
const name = process.argv[2] || 'write';
if (!existsSync(join(EMU, 'package.json'))) { console.error('emulator not found: ' + EMU); process.exit(1); }
const biosPath = join(root, 'bios.path');
if (!process.env.BIOS_ROM && existsSync(biosPath)) process.env.BIOS_ROM = readFileSync(biosPath, 'utf8').split(/\r?\n/)[0].trim();
if (!process.env.BIOS_ROM || !existsSync(process.env.BIOS_ROM)) { console.error('BIOS KEYB/SD not found: set BIOS_ROM or write its path in bios.path'); process.exit(1); }
const { build } = createRequire(join(EMU, 'package.json'))('esbuild');
const out = join(here, `.${name}.test.mjs`);
const slash = (p) => p.split(String.fromCharCode(92)).join('/');
await build({
  entryPoints: [join(here, `${name}.test.ts`)], outfile: out, bundle: true, platform: 'node', format: 'esm',
  logLevel: 'error', alias: { EMU: slash(EMU) }, define: { __ROOT__: JSON.stringify(slash(root)) },
});
const mod = await import(pathToFileURL(out).href);
try { await mod.default(); console.log('ALL OK'); } catch (e) { console.error('FAIL ' + (e.stack || e)); process.exit(1); }
