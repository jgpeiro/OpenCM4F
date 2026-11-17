# Prebuilt files

* `opencm4f_tangnano20k.fs`: bitstream for the Tang Nano 20K (GW2AR-LV18QN88C8/I7) made with the
  open-source flow (`scripts/run_pnr.sh`) from the sources in this tree, firmware included.
  `openFPGALoader -b tangnano20k opencm4f_tangnano20k.fs` (add `-f` to write the flash).
* `firmware.bin`, `firmware.elf`: the benchmark firmware in the code ROM (`make -C fw`).

Wiring: 480x272 RGB LCD on the 40-pin FPC connector (as in Sipeed's lcd_480_272 example), KY-040
rotary encoder on pins 20 (CLK), 19 (DT), 18 (SW), 3.3 V and GND. LED0 lights while the core runs,
LED1 after a lockup.
