# OpenCM4F Bench firmware: clang + lld (no libc), Thumb-2, FPv4-SP hard float
#   make            -> firmware.elf / .bin / .lst / .map and rtl/soc/init_rom.vh (the code ROM contents)
#   make sim        -> sim/firmware.* with short runs, for the Verilator SoC testbench (SIMDEFS=-DSIM_RUN=n)
CC      = clang --target=thumbv7em-none-eabihf -mcpu=cortex-m4 -mfpu=fpv4-sp-d16 -mfloat-abi=hard
OPT     = -O2 -fno-unroll-loops
# the benchmarks at -O2 (no loop unrolling); the UI and the libraries for size (32 KB ROM)
SMALL   = crt0.c main.c ui.c pages.c gfx.c bench.c minilib.c mathf.c coremark/core_portme.c
CFLAGS  = -ffreestanding -fno-builtin -nostdlib -Wall -Wno-unused-function -ffunction-sections \
          -fdata-sections -fno-common -I. -Icoremark -Idhry $(DEFS)
OUT    ?= build
OBJ     = crt0.o main.o ui.o pages.o gfx.o bench.o bm_kernels.o bm_isa.o mathf.o minilib.o \
          dhry/dhry_main.o dhry/dhrystone.o \
          coremark/core_list_join.o coremark/cm_main.o coremark/core_matrix.o coremark/core_state.o \
          coremark/core_util.o coremark/core_portme.o
OBJS    = $(addprefix $(OUT)/,$(OBJ))
DHRY    = -std=gnu89 -fno-inline -DOCM4F -Wno-implicit-int -Wno-implicit-function-declaration \
          -Wno-return-type -Wno-strict-prototypes -Wno-deprecated-non-prototype -Wno-unknown-pragmas \
          -Wno-incompatible-library-redeclaration
CMF     = -DFLAGS_STR='"$(OPT)"'

all: $(OUT)/firmware.bin
	python3 ../tools/gen_init.py fw $(OUT)/firmware.bin

$(OUT)/%.o: %.c *.h coremark/*.h dhry/*.h Makefile
	@mkdir -p $(dir $@)
	$(CC) $(if $(filter $<,$(SMALL)),-Oz,$(OPT)) $(CFLAGS) $(if $(findstring dhry/,$<),$(DHRY)) $(if $(findstring coremark/,$<),$(CMF)) \
	  $(if $(findstring bm_kernels,$<),$(shell python3 ../tools/kernels_ref.py)) -c $< -o $@

$(OUT)/firmware.elf: $(OBJS) link.ld
	$(CC) -fuse-ld=lld -nostdlib -T link.ld -Wl,--gc-sections -Wl,-Map,$(OUT)/firmware.map $(OBJS) -o $@
	@llvm-size $@ 2>/dev/null || llvm-size-18 $@

$(OUT)/firmware.bin: $(OUT)/firmware.elf
	llvm-objcopy -O binary $< $@
	llvm-objdump -d --no-show-raw-insn $< > $(OUT)/firmware.lst 2>/dev/null || llvm-objdump-18 -d $< > $(OUT)/firmware.lst

sim:
	$(MAKE) OUT=sim DEFS="-DSIM $(SIMDEFS)" sim/firmware.bin

# quick runs (0.25 s per benchmark, CoreMark 1 s) started at once: for a long SoC simulation
simq:
	$(MAKE) OUT=simq DEFS="-DQUICK -DSIM_RUN=9" simq/firmware.bin

clean:
	rm -rf build sim simq
.PHONY: all sim simq clean
