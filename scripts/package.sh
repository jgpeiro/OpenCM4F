#!/bin/bash
# Makes opencm4f.zip: sources, docs, firmware image, bitstream (no build directories)
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/.."
rm -f opencm4f.zip
zip -qr opencm4f.zip opencm4f \
  -x 'opencm4f/build/*' 'opencm4f/fw/build/*.o' 'opencm4f/fw/build/*/*.o' 'opencm4f/fw/sim/*' 'opencm4f/fw/simq/*' \
     '*/__pycache__/*' 'opencm4f/tb/cocotb/results.xml' 'opencm4f/tb/cocotb/dump.fst' '*.pyc'
ls -la opencm4f.zip
