"""Counts the flip-flops of a synthesized Gowin netlist (yosys JSON) that need a pass-through LUT in
nextpnr: the D input is not driven by a LUT / ALU output of its own (driven by another FF, a block
RAM, a DSP, an input, a constant, or a LUT that also drives other flip-flops).
usage: ff_report.py build/pnr/opencm4f.json [depth]"""
import json, sys, collections, re
detail = '-d' in sys.argv
sys.argv = [a for a in sys.argv if a != '-d']
d = json.load(open(sys.argv[1]))
depth = int(sys.argv[2]) if len(sys.argv) > 2 else 4
mods = d['modules']
top = [m for m in mods if mods[m].get('attributes', {}).get('top')][0]
m = mods[top]
drv = {}                       # bit -> (cell, type, port)
sinks = collections.defaultdict(list)
for cn, c in m['cells'].items():
    for p, bits in c['connections'].items():
        dirn = c.get('port_directions', {}).get(p, 'input')
        for b in bits:
            if isinstance(b, str):
                continue
            if dirn == 'output':
                drv[b] = (cn, c['type'], p)
            else:
                sinks[b].append((cn, c['type'], p))
def scope(cn):
    nm = m['cells'][cn].get('attributes', {}).get('hdlname') or cn
    parts = nm.replace(' ', '.').split('.')
    sc = '.'.join(parts[:-1][:depth - 1]) or '(top)'
    return sc + ':' + re.sub(r'_(DFF\w*|LUT\w*)_Q.*$|_DFF\w*$', '', parts[-1]) if detail else sc
need = collections.Counter(); tot = collections.Counter(); why = collections.Counter()
for cn, c in m['cells'].items():
    if not c['type'].startswith('DFF'):
        continue
    b = c['connections']['D'][0]
    sc = scope(cn)
    tot[sc] += 1
    if isinstance(b, str):
        need[sc] += 1; why['const'] += 1; continue
    dv = drv.get(b)
    if dv is None:
        need[sc] += 1; why['port'] += 1; continue
    t = dv[1]
    if t.startswith('LUT') or t == 'ALU' or t.startswith('MUX2'):
        nff = sum(1 for s in sinks[b] if s[1].startswith('DFF') and s[2] == 'D')
        if nff > 1:
            need[sc] += 1; why['shared LUT'] += 1
    else:
        need[sc] += 1; why[t] += 1
print('flip-flops', sum(tot.values()), 'needing a pass-through LUT', sum(need.values()))
print('by driver:', dict(why))
for sc, n in sorted(need.items(), key=lambda x: -x[1])[:int(__import__("os").environ.get("TOPN", "30"))]:
    print(f'  {n:5d} / {tot[sc]:5d}  {sc}')
