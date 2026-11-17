#!/bin/bash
# quick area estimate of the whole SoC (flattened, as for P&R): LUT + ALU + 8 per RAM16SDP4
# usage: scripts/area.sh <tag> [extra synth_gowin options]
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAG=$1; shift
OUT=$ROOT/build/area; mkdir -p $OUT
cd $ROOT/rtl/soc; C=../core
yosys -q -l $OUT/$TAG.log -p "read_verilog -I$C -I. tangnano20k_top.v ocm4_soc.v gpu.v encoder.v $C/opencm4f.v $C/ocm4_core.v \
  $C/ocm4_fetch.v $C/ocm4_decode.v $C/ocm4_regfile.v $C/ocm4_alu.v $C/ocm4_bitops.v $C/ocm4_mul.v $C/ocm4_div.v $C/ocm4_lsu.v \
  $C/ocm4_scs.v $C/ocm4_fpu.v; synth_gowin -family gw2a -nowidelut $* -top tangnano20k_top -json $OUT/$TAG.json; tee -q -o $OUT/$TAG.stat stat" >/dev/null 2>&1
python3 - $OUT/$TAG.stat <<'PY'
import re,sys
t=open(sys.argv[1]).read()
def g(k): return sum(int(x) for x in re.findall(r'^\s+(\d+)\s+'+k+r'\s*$',t,re.M))
lut=sum(g(k) for k in ['LUT1','LUT2','LUT3','LUT4']); alu=g('ALU'); r16=g('RAM16SDP4')
ff=sum(g(k) for k in ['DFF','DFFE','DFFR','DFFRE','DFFS','DFFSE','DFFN','DFFNE'])
print(f"LUT {lut} ALU {alu} RAM16 {r16} -> LUT4 equiv {lut+alu+8*r16} (+chain heads ~{alu//7}) = {(lut+alu+8*r16+alu//7)/207.36:.1f}%  FF {ff}")
PY
python3 $ROOT/tools/ff_report.py $OUT/$TAG.json 5 | head -2
