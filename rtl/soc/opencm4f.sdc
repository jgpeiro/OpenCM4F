// OpenCM4F on the Tang Nano 20K: the 27 MHz crystal, the PLL outputs (renderer / LCD 54 MHz, CPU 27 MHz)
create_clock -name clk_in  -period 37.037 -waveform {0 18.518} [get_ports {clk}]
create_clock -name clk_pix -period 18.518 -waveform {0 9.259}  [get_nets {clk_pix}]
create_clock -name clk_cpu -period 37.037 -waveform {0 18.518} [get_nets {clk_cpu}]
// the clocks meet only in dual-clock block RAMs and two-flop synchronisers (rtl/soc/ocm4_soc.v)
set_clock_groups -asynchronous -group [get_clocks {clk_pix}] -group [get_clocks {clk_cpu}]
