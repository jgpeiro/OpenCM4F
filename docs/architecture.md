# OpenCM4F architecture

## Block diagram

```
                        +------------------------------------------------------------------+
   M_AXI_I (AR, R) <--- | F  ocm4_fetch   word fetches, 2 in flight, 8-halfword queue       |
                        |                 redirect: flush, new address out in the same clock |
                        +-------------------------------+----------------------------------+
                                                        | hw0, hw1, pc0 (consume 0 / 1 / 2)
                        +-------------------------------v----------------------------------+
                        | D  ocm4_decode  Thumb / Thumb-2 / DSP / VFP -> one micro-op       |
                        |    register files (LUT RAM): R 16 x 32 (4 read ports),           |
                        |    S 32 x 32 (3 read ports: Sn, Sm in D, Sd and stores in X)      |
                        |    bypass from the write ports; IT state                         |
                        +-------------------------------+----------------------------------+
                                                        | x_op, x_sub, x_a, x_b, x_c, x_imm, ...
                        +-------------------------------v----------------------------------+
                        | X  execute (state machine: RUN, EXC entry, RET, SLEEP, HALT, LOCK)|
                        |    ocm4_shifter + ocm4_alu          1 clock                       |
                        |    ocm4_bitops (SIMD, saturate, bit field, CLZ, RBIT, REV, SEL)   |
                        |    ocm4_mul (MULT36X36 + MULT18X18)  2 clocks                     |
                        |    ocm4_div                          2 + bits / 2 clocks           |
                        |    ocm4_fpu (multi-cycle, shared datapath)                        |
                        |    load / store sequencer -> ocm4_lsu -> M_AXI_D / SCS             |
                        |    branches, MRS / MSR / CPS, exceptions (stacking, vector read,   |
                        |    unstacking, lazy FP state)                                     |
                        +------------------------------------------------------------------+
                          ocm4_scs: NVIC, SCB, SysTick, DWT, FP control  (inside the core)
```

## Pipeline

* **Fetch** keeps up to two word reads in flight and a circular queue of eight halfwords; it fetches
  ahead while there is room for the words in flight. A redirect (taken branch, exception, exception
  return) flushes the queue, drops the responses of reads issued before it and puts the new address
  on AR in the same clock (unless an earlier AR is still waiting for ARREADY). A target on an odd
  halfword drops the first halfword of its word. RRESP errors travel with the halfwords and give a
  BusFault (IBUSERR) only if the instruction is executed.
* **Decode** turns the first one or two halfwords of the queue into a micro-op (operation, sub-op,
  register numbers, immediate, flags to set, condition) and reads the register files. The values the
  execute stage writes in the same clock are forwarded. Inside IT blocks the condition comes from the
  IT state. A micro-op issues when the execute stage is empty or finishes an instruction that does
  not change the flow.
* **Execute** is a state machine with a step counter: most instructions take one clock; loads,
  stores, LDM / STM / PUSH / POP, VLDM / VSTM, multiplies, divides, FP operations and the system
  instructions take several. Branches and writes to the PC resolve here. Asynchronous exceptions
  are taken when the stage is empty (issue stops while one is pending); LDM, STM and divisions run
  to the end first.

## Exceptions

Entry: frame pointer and alignment (STKALIGN), push of R0-R3, R12, LR, PC, xPSR (and the FP
space S0-S15, FPSCR if CONTROL.FPCA: with FPCCR.LSPEN the FP registers are not written at entry, the
address goes to FPCAR and the first FP instruction in the handler stores them), vector read
(VTOR), SP update, LR = EXC_RETURN. Return (BX / POP / LDM of an EXC_RETURN value in handler mode):
integrity checks (UsageFault INVPC), unstacking, the stacked xPSR's IT / T bits and the 4-byte
realignment, CONTROL.FPCA from EXC_RETURN[4]. Faults during stacking / unstacking set the stacking
bits of the CFSR and escalate as the architecture says; a fault at a priority that cannot preempt
escalates to HardFault, a HardFault at priority -1 locks the core up.

The NVIC keeps priorities as levels (0 NMI, 1 HardFault, 2 + priority) and chooses the highest
pending exception one clock ahead; whether it preempts is decided against the current execution
priority (active exceptions, PRIMASK, FAULTMASK, BASEPRI) in the same clock.

## FPU

One operation at a time on a shared datapath:
`UNPK` (unpack, normalise subnormals, special cases) -> `MUL` (24 x 24, an addition multiplies its
first operand by 1.0) -> `ALN` (align the addend, 52-bit shift with sticky) -> `ADD` -> `NRM`
(leading-zero count and normalise) -> `RND1` (denormalise tiny results or flush to zero) -> `RND2`
(round, overflow, pack). Division (radix 2, 2 bits per clock) and square root (digit recurrence)
have their own states, as do conversions to integer / fixed point. VMLA-type instructions (rounded
product, then rounded sum) run the datapath twice; VFMA-type instructions round once. Results are
bit-exact with the ARMv7-M pseudo-code (verified against Unicorn, which uses QEMU's softfloat):
default NaN, flush-to-zero, alternative half precision, all four rounding modes, tininess before
rounding, the cumulative flags.

## Load / store unit

One request per clock from the execute stage; byte, halfword or word at any alignment (an access
that crosses a word boundary becomes two transactions, as the Cortex-M4 does for LDR / LDRH / STR /
STRH; LDRD / STRD / LDM / STM / LDREX / STREX / VLDR / VSTR fault when unaligned). Writes are posted
(acknowledged when AW and W are accepted; a B error is an imprecise BusFault); a read waits until no
write is outstanding, so read-after-write order holds on any interconnect. Addresses 0xE000_0000 ..
0xE00F_FFFF go to the SCS. An exclusive monitor serves LDREX / STREX / CLREX (cleared by exception
entry and return).

## Performance counters

`perf_ev[6:0]` reports, every clock, at most one of: instruction retired, execute stage empty
(fetch / branch bubble), load / store wait, multiply / divide step, FPU step, exception entry /
return, sleep. The SoC counts these into eight 32-bit counters (the eighth class, "other", is every
clock with none of them: multi-cycle ALU / system steps, halt).

## Area and timing (Gowin GW2AR-18, open-source flow)

yosys `synth_gowin -nowidelut`, hierarchy kept, NUM_IRQ = 1, PRIO_BITS = 3 (LUT = LUT1..LUT4 cells;
nextpnr counts each ALU cell and 8 LUTs per RAM16SDP4 in its LUT4 figure as well):

| unit | LUT | ALU | FF | other |
|---|---:|---:|---:|---|
| ocm4_core (control, execute, write-back, exceptions) | 3495 | 502 | 857 | |
| ocm4_fpu | 3312 | 672 | 687 | 1 MULT36X36 |
| ocm4_bitops | 1594 | 304 | 0 | |
| ocm4_decode | 1195 | 37 | 0 | |
| ocm4_scs (NVIC, SCB, SysTick, DWT) | 883 | 180 | 323 | |
| ocm4_fetch | 524 | 127 | 244 | |
| ocm4_mul | 400 | 130 | 104 | 1 MULT36X36, 1 MULT18X18 |
| ocm4_div | 393 | 171 | 104 | |
| ocm4_lsu | 376 | 30 | 61 | |
| ocm4_shifter | 331 | 4 | 0 | |
| ocm4_alu | 250 | 33 | 0 | |
| register files | 130 | 0 | 0 | 32 + 48 RAM16SDP4 |
| **OpenCM4F** | **12883** | **2190** | **2380** | 80 RAM16SDP4, 3 DSP blocks |

The whole Tang Nano 20K system (CPU, 32 KB ROM, 24 KB RAM, renderer, display list, I/O, PERF
counters) after place and route: 18493 of 20736 LUT4 positions (89 %, including 3526 ALU cells and
the LUT RAM), 3914 FFs, 88 RAM16SDP4, 44 of 46 BSRAM, 2 MULT36X36, 7 MULT18X18, 13 MULT9X9, 1 rPLL.

Fitting notes (nextpnr-himbaechel): a flip-flop whose D input is not driven by a LUT or ALU of its
own (another flip-flop, a block RAM, a DSP output, a LUT shared by several flip-flops) gets a
pass-through LUT. `tools/ff_report.py` lists them; the renderer's per-command values live in two
slots instead of travelling down the pixel pipeline for that reason.

The design meets the clocks of the Tang Nano 20K system with the open-source flow: the CPU domain at
27 MHz and the renderer at 54 MHz (see the README for the numbers of the last run). The longest CPU
paths go from the execute-stage registers through the address adder, the load / store unit's
handshake and the completion logic to the issue of the next micro-op into the execute registers.
Moving that issue decision one clock earlier, or resolving unconditional branches in decode, are the
obvious next steps for clock rate and CPI.

## Verification approach

The lockstep harness (`tb/cocotb/harness.py`, `armref.py`) assembles a program with clang / llvm-mc,
loads it into the testbench memory (`tb/axil_mem.v`, random stalls on every channel) and into
Unicorn, and runs the core. For every instruction the core retires (trace port), Unicorn runs to the
same architectural PC; then all R registers, the flags, all S registers and FPSCR are compared.
Programs that end write TOHOST; the data memory is compared at the end. The FPU bench drives the FPU
alone with random and special operands for every operation and FPSCR mode and compares the result and
the flags with Unicorn running the same VFP instruction.
