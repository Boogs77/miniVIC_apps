# fixbranch.py - turns the conditional branches vasm reports as out of range into
# "opposite branch over a JMP" (assembles again until none is left)
#   python tools/fixbranch.py apps/calc.asm
import re, subprocess, sys
src = sys.argv[1]
vasm = open('vasm.path').readline().strip()
OPP = {'BCS': 'BCC', 'BCC': 'BCS', 'BEQ': 'BNE', 'BNE': 'BEQ', 'BMI': 'BPL', 'BPL': 'BMI', 'BVS': 'BVC', 'BVC': 'BVS'}
n = 0
for _ in range(20):
    r = subprocess.run([vasm, '-Fbin', '-dotdir', '-c02', '-quiet', '-o', 'NUL', src], capture_output=True, text=True)
    errs = re.findall(r'error 2007 in line (\d+) of "([^"]+)"', r.stdout + r.stderr)
    if not errs:
        break
    byfile = {}
    for ln, f in errs:
        byfile.setdefault(f.replace(chr(92), '/'), set()).add(int(ln))
    for f, lines in byfile.items():
        text = open(f, encoding='utf-8').read().split('\n')
        for ln in sorted(lines, reverse=True):
            m = re.match(r'(\s*)(B[A-Z]{2})\s+(\S+)(.*)$', text[ln - 1])
            if m and m.group(2) == 'BRA':
                text[ln - 1] = f'{m.group(1)}JMP {m.group(3)}{m.group(4)}'
                n += 1
                continue
            if not m or m.group(2) not in OPP:
                continue
            n += 1
            lab = f'.fb{n}'
            text[ln - 1:ln] = [f'{m.group(1)}{OPP[m.group(2)]} {lab}{m.group(4)}', f'{m.group(1)}JMP {m.group(3)}', f'{lab}:']
        open(f, 'w', encoding='utf-8', newline='').write('\n'.join(text))
print(f'{n} branches changed')
