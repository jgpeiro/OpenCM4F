/*
 * tangnano20k_top - OpenCM4F benchmark system on the Sipeed Tang Nano 20K with the 480x272 RGB LCD
 * SPDX-License-Identifier: MIT
 *
 *   27 MHz crystal -> rPLL -> 54 MHz renderer / LCD clock (the 9 MHz LCD clock is made from it in gpu)
 *                          -> CLKOUTD = 54 / 2 = 27 MHz CPU clock (edges aligned with the 54 MHz clock)
 *   S1 (pin 88), S2 (pin 87); rotary encoder: CLK pin 20, DT pin 19, SW pin 18
 *   LED0 (pin 15) on while the core runs, LED1 (pin 16) on after a lockup (active low LEDs)
 */

`default_nettype none

module tangnano20k_top (
    input  wire       clk,          // 27 MHz crystal (pin 4)
    input  wire       btn_s1,       // high while pressed
    input  wire       btn_s2,
    input  wire       enc_clk,
    input  wire       enc_dt,
    input  wire       enc_sw,

    output wire       lcd_clk,
    output wire       lcd_de,
    output wire       lcd_hsync,
    output wire       lcd_vsync,
    output wire [4:0] lcd_r,
    output wire [5:0] lcd_g,
    output wire [4:0] lcd_b,
    output wire [1:0] led
);

  // CLKOUT = 27 * (FBDIV_SEL + 1) / (IDIV_SEL + 1) = 54 MHz, VCO = 54 * ODIV_SEL = 864 MHz
  wire clk_pix, clk_cpu, pll_lock;
  rPLL #(
      .FCLKIN("27"), .DYN_IDIV_SEL("false"), .IDIV_SEL(0), .DYN_FBDIV_SEL("false"), .FBDIV_SEL(1),
      .DYN_ODIV_SEL("false"), .ODIV_SEL(16), .PSDA_SEL("0000"), .DYN_DA_EN("true"), .DUTYDA_SEL("1000"),
      .CLKOUT_FT_DIR(1'b1), .CLKOUTP_FT_DIR(1'b1), .CLKOUT_DLY_STEP(0), .CLKOUTP_DLY_STEP(0),
      .CLKFB_SEL("internal"), .CLKOUT_BYPASS("false"), .CLKOUTP_BYPASS("false"), .CLKOUTD_BYPASS("false"),
      .DYN_SDIV_SEL(2), .CLKOUTD_SRC("CLKOUT"), .CLKOUTD3_SRC("CLKOUT"), .DEVICE("GW2AR-18C")
  ) u_pll (
      .CLKOUT(clk_pix), .LOCK(pll_lock), .CLKOUTP(), .CLKOUTD(clk_cpu), .CLKOUTD3(), .RESET(1'b0), .RESET_P(1'b0),
      .CLKIN(clk), .CLKFB(1'b0), .FBDSEL(6'b000000), .IDSEL(6'b000000), .ODSEL(6'b000000), .PSDA(4'b0000),
      .DUTYDA(4'b0000), .FDLY(4'b0000));

  // resets: held until the PLL locks, released synchronously in each clock domain
  reg [3:0] rst_sync, rst_pix_sync;
  always @(posedge clk_cpu) rst_sync <= {rst_sync[2:0], pll_lock};
  always @(posedge clk_pix) rst_pix_sync <= {rst_pix_sync[2:0], pll_lock};
  wire rst_n = rst_sync[3];

  // buttons: two-flop synchronisers
  reg [1:0] s1_sync, s2_sync;
  always @(posedge clk_cpu) begin
    s1_sync <= {s1_sync[0], btn_s1};
    s2_sync <= {s2_sync[0], btn_s2};
  end

  wire [15:0] rgb;
  wire        lockup, halted;
  ocm4_soc u_soc (
      .clk(clk_cpu), .rst_n(rst_n), .clk_pix(clk_pix), .rst_pix_n(rst_pix_sync[3]), .buttons({s2_sync[1], s1_sync[1]}),
      .enc_clk(enc_clk), .enc_dt(enc_dt), .enc_sw(enc_sw),
      .lcd_clk(lcd_clk), .lcd_de(lcd_de), .lcd_hs(lcd_hsync), .lcd_vs(lcd_vsync), .lcd_rgb(rgb),
      .lockup(lockup), .halted(halted));
  assign lcd_r = rgb[15:11];
  assign lcd_g = rgb[10:5];
  assign lcd_b = rgb[4:0];
  assign led   = {~lockup, ~rst_n};

endmodule

`default_nettype wire
