// gpu with display-list, gdata and image memories, for tb_gpu.cpp (memories are loaded by the testbench)
`default_nettype none
module gpu_wrap (input wire clk, input wire rst_n, input wire bank_sel, input wire [15:0] bg,
                 input wire pal_we, input wire [4:0] pal_wa, input wire [15:0] pal_wd,
                 output wire lcd_clk, output wire lcd_de, output wire lcd_hs, output wire lcd_vs,
                 output wire [15:0] lcd_rgb, output wire [31:0] frame_cnt, output wire [15:0] stat_max,
                 output wire [15:0] stat_over);
  reg [127:0] dl [0:511];
  reg [31:0]  gd [0:2047];
  reg [31:0]  img [0:4095];
  wire [8:0]  dl_addr;
  wire [10:0] gd_addr;
  wire [11:0] im_addr;
  reg [127:0] dl_q;
  reg [31:0]  gd_q, im_q;
  always @(posedge clk) begin dl_q <= dl[dl_addr]; gd_q <= gd[gd_addr]; im_q <= img[im_addr]; end
  gpu u_gpu (.clk(clk), .rst_n(rst_n), .dl_addr(dl_addr), .dl_data(dl_q), .gd_addr(gd_addr), .gd_data(gd_q),
             .im_addr(im_addr), .im_busy(), .im_data(im_q), .pal_we(pal_we), .pal_wa(pal_wa), .pal_wd(pal_wd),
             .bank_sel(bank_sel), .bg(bg), .frame_cnt(frame_cnt), .stat_max(stat_max), .stat_over(stat_over),
             .lcd_clk(lcd_clk), .lcd_de(lcd_de), .lcd_hs(lcd_hs), .lcd_vs(lcd_vs), .lcd_rgb(lcd_rgb));
endmodule
