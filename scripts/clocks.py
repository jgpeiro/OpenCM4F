# nextpnr pre-pack script: the two clocks of the OpenCM4F SoC (rtl/soc/tangnano20k_top.v)
ctx.addClock("clk_pix", 54)     # renderer and LCD
ctx.addClock("clk_cpu", 27)     # CPU, memories, I/O (CLKOUTD = 54 / 2)
