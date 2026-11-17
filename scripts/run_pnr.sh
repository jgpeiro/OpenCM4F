#!/bin/bash
# Open-source build of the Tang Nano 20K bitstream: yosys (synth_gowin) -> nextpnr-himbaechel -> gowin_pack
# usage: scripts/run_pnr.sh <out_dir> [seed]      (build the firmware first: make -C fw)
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mkdir -p "$1" && cd "$1" && pwd)"
SEED=${2:-1}
YOSYS=${YOSYS:-$(command -v yosys || command -v yowasp-yosys)}                     # yosys >= 0.40
NEXTPNR=${NEXTPNR:-$(command -v nextpnr-himbaechel || command -v yowasp-nextpnr-himbaechel-gowin)}
GOWIN_PACK=${GOWIN_PACK:-$(command -v gowin_pack)}
cd "$ROOT/rtl/soc"
CORE="../core"
$YOSYS -q -l "$OUT/synth.log" -p "read_verilog -I$CORE -I. tangnano20k_top.v ocm4_soc.v gpu.v encoder.v \
  $CORE/opencm4f.v $CORE/ocm4_core.v $CORE/ocm4_fetch.v $CORE/ocm4_decode.v $CORE/ocm4_regfile.v $CORE/ocm4_alu.v \
  $CORE/ocm4_bitops.v $CORE/ocm4_mul.v $CORE/ocm4_div.v $CORE/ocm4_lsu.v $CORE/ocm4_scs.v $CORE/ocm4_fpu.v; \
  synth_gowin -family gw2a -nowidelut -top tangnano20k_top -json $OUT/opencm4f.json; tee -o $OUT/synth_stat.txt stat"
$NEXTPNR --json "$OUT/opencm4f.json" --write "$OUT/opencm4f_pnr.json" --device GW2AR-LV18QN88C8/I7 \
  --vopt family=GW2A-18C --vopt cst=tangnano20k.cst --pre-pack "$ROOT/scripts/clocks.py" --freq 27 --seed "$SEED" \
  -l "$OUT/pnr.log"
$GOWIN_PACK -d GW2A-18C -o "$OUT/opencm4f.fs" "$OUT/opencm4f_pnr.json"
python3 "$ROOT/tools/fs_header.py" "$OUT/opencm4f.fs"
grep "Max frequency" "$OUT/pnr.log" | tail -2
echo "bitstream: $OUT/opencm4f.fs"
