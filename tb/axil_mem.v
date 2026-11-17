/*
 * axil_mem - testbench memory for OpenCM4F: two AXI4-Lite slave ports (instruction, data) on one
 * RAM, random back-pressure and response delays, and a few test registers.
 * SPDX-License-Identifier: MIT
 *
 *   0x0000_0000 .. 4*WORDS-1   RAM (initialised from +HEX=<file>, one 32-bit word per line)
 *   0x6000_0000 .. 0x6FFF_FFFF answers SLVERR (bus fault tests)
 *   0xF000_0000  TOHOST  (w) end of test, the value is the result (0 = pass)
 *   0xF000_0004  PUTC    (w) character to the console
 *   0xF000_0008  IRQ     (w) level of the interrupt lines
 *   0xF000_000C  CYCLES  (r) clock counter
 *   0xF000_0010  NMI     (w) bit 0 drives the NMI line
 *   0xF000_0014  SCRATCH (rw)
 *   anything else: DECERR
 * Responses are in order on each port; reads see the memory as it is when the address is accepted.
 */

`default_nettype none

module axil_mem #(
    parameter WORDS = 65536
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [7:0]  stall,          // 0: never stall, 255: stall most of the time
    input  wire [31:0] seed,

    input  wire [31:0] i_araddr,
    input  wire        i_arvalid,
    output wire        i_arready,
    output wire [31:0] i_rdata,
    output wire [1:0]  i_rresp,
    output wire        i_rvalid,
    input  wire        i_rready,

    input  wire [31:0] d_awaddr,
    input  wire        d_awvalid,
    output wire        d_awready,
    input  wire [31:0] d_wdata,
    input  wire [3:0]  d_wstrb,
    input  wire        d_wvalid,
    output wire        d_wready,
    output wire [1:0]  d_bresp,
    output wire        d_bvalid,
    input  wire        d_bready,
    input  wire [31:0] d_araddr,
    input  wire        d_arvalid,
    output wire        d_arready,
    output wire [31:0] d_rdata,
    output wire [1:0]  d_rresp,
    output wire        d_rvalid,
    input  wire        d_rready,

    output reg  [31:0] tohost,
    output reg         tohost_we,
    output reg  [7:0]  putc_char,
    output reg         putc_we,
    output reg  [31:0] irq_lines,
    output reg         nmi_line
);
  reg [31:0] mem [0:WORDS-1] /* verilator public */;
  reg [1023:0] hexfile;
  integer k;
  initial begin
    for (k = 0; k < WORDS; k = k + 1) mem[k] = 32'd0;
    if ($value$plusargs("HEX=%s", hexfile)) $readmemh(hexfile, mem);
  end

  // ---------------- random stalls (xorshift) ----------------
  reg  [31:0] lfsr;
  wire [31:0] x1 = lfsr ^ (lfsr << 13);
  wire [31:0] x2 = x1 ^ (x1 >> 17);
  wire [31:0] x3 = x2 ^ (x2 << 5);
  always @(posedge clk) begin
    if (!rst_n) lfsr <= seed | 32'd1;
    else lfsr <= x3;
  end
  wire st_iar = (lfsr[7:0] < stall);
  wire st_ir  = (lfsr[15:8] < stall);
  wire st_dar = (lfsr[23:16] < stall);
  wire st_dr  = (lfsr[31:24] < stall);
  wire st_dw  = (lfsr[11:4] < stall);
  wire st_db  = (lfsr[19:12] < stall);

  reg [31:0] cycles;
  reg [31:0] scratch;
  always @(posedge clk) cycles <= rst_n ? cycles + 32'd1 : 32'd0;

  function in_ram(input [31:0] a);
    in_ram = (a < 4 * WORDS);
  endfunction

  // read data / response for an address (data port sees the test registers)
  function [33:0] rd(input [31:0] a, input dport);
    begin
      if (in_ram(a))                      rd = {2'b00, mem[a[31:2]]};
      else if (a[31:28] == 4'h6)          rd = {2'b10, 32'hDEADBEEF};
      else if (dport && a == 32'hF000000C) rd = {2'b00, cycles};
      else if (dport && a == 32'hF0000014) rd = {2'b00, scratch};
      else if (dport && a == 32'hF0000008) rd = {2'b00, irq_lines};
      else if (dport && a == 32'hF0000010) rd = {2'b00, 31'd0, nmi_line};
      else if (dport && a[31:8] == 24'hF00000) rd = {2'b00, 32'd0};
      else                                 rd = {2'b11, 32'hBADADD00};
    end
  endfunction

  // ---------------- instruction port: FIFO of 4 responses ----------------
  reg [33:0] iq [0:3];
  reg [2:0]  iq_n;
  reg [1:0]  iq_h;
  assign i_arready = (iq_n < 3'd4) && !st_iar;
  assign i_rvalid  = (iq_n != 3'd0) && !st_ir;
  assign i_rdata   = iq[iq_h][31:0];
  assign i_rresp   = iq[iq_h][33:32];
  wire i_ar = i_arvalid && i_arready;
  wire i_r  = i_rvalid && i_rready;
  always @(posedge clk) begin
    if (!rst_n) begin
      iq_n <= 3'd0; iq_h <= 2'd0;
    end else begin
      if (i_ar) iq[iq_h + iq_n[1:0]] <= rd({i_araddr[31:2], 2'b00}, 1'b0);
      if (i_r) iq_h <= iq_h + 2'd1;
      iq_n <= iq_n + (i_ar ? 3'd1 : 3'd0) - (i_r ? 3'd1 : 3'd0);
    end
  end

  // ---------------- data port: reads ----------------
  reg [33:0] dq [0:3];
  reg [2:0]  dq_n;
  reg [1:0]  dq_h;
  assign d_arready = (dq_n < 3'd4) && !st_dar;
  assign d_rvalid  = (dq_n != 3'd0) && !st_dr;
  assign d_rdata   = dq[dq_h][31:0];
  assign d_rresp   = dq[dq_h][33:32];
  wire d_ar = d_arvalid && d_arready;
  wire d_r  = d_rvalid && d_rready;
  always @(posedge clk) begin
    if (!rst_n) begin
      dq_n <= 3'd0; dq_h <= 2'd0;
    end else begin
      if (d_ar) dq[dq_h + dq_n[1:0]] <= rd({d_araddr[31:2], 2'b00}, 1'b1);
      if (d_r) dq_h <= dq_h + 2'd1;
      dq_n <= dq_n + (d_ar ? 3'd1 : 3'd0) - (d_r ? 3'd1 : 3'd0);
    end
  end

  // ---------------- data port: writes (AW and W together) ----------------
  reg [1:0] bq [0:3];
  reg [2:0] bq_n;
  reg [1:0] bq_h;
  wire      w_ok = d_awvalid && d_wvalid && (bq_n < 3'd4) && !st_dw;
  assign d_awready = w_ok;
  assign d_wready  = w_ok;
  assign d_bvalid  = (bq_n != 3'd0) && !st_db;
  assign d_bresp   = bq[bq_h];
  wire d_b = d_bvalid && d_bready;
  wire [31:0] wa = d_awaddr;
  always @(posedge clk) begin
    tohost_we <= 1'b0;
    putc_we <= 1'b0;
    if (!rst_n) begin
      bq_n <= 3'd0; bq_h <= 2'd0; irq_lines <= 32'd0; nmi_line <= 1'b0; tohost <= 32'd0; scratch <= 32'd0;
    end else begin
      if (w_ok) begin
        if (in_ram(wa)) begin
          if (d_wstrb[0]) mem[wa[31:2]][7:0]   <= d_wdata[7:0];
          if (d_wstrb[1]) mem[wa[31:2]][15:8]  <= d_wdata[15:8];
          if (d_wstrb[2]) mem[wa[31:2]][23:16] <= d_wdata[23:16];
          if (d_wstrb[3]) mem[wa[31:2]][31:24] <= d_wdata[31:24];
          bq[bq_h + bq_n[1:0]] <= 2'b00;
        end else if (wa[31:28] == 4'h6) begin
          bq[bq_h + bq_n[1:0]] <= 2'b10;
        end else if (wa[31:8] == 24'hF00000) begin
          bq[bq_h + bq_n[1:0]] <= 2'b00;
          case (wa[7:0])
            8'h00: begin tohost <= d_wdata; tohost_we <= 1'b1; end
            8'h04: begin putc_char <= d_wdata[7:0]; putc_we <= 1'b1; end
            8'h08: irq_lines <= d_wdata;
            8'h10: nmi_line <= d_wdata[0];
            8'h14: scratch <= d_wdata;
            default: ;
          endcase
        end else begin
          bq[bq_h + bq_n[1:0]] <= 2'b11;
        end
      end
      if (d_b) bq_h <= bq_h + 2'd1;
      bq_n <= bq_n + (w_ok ? 3'd1 : 3'd0) - (d_b ? 3'd1 : 3'd0);
    end
  end

endmodule

`default_nettype wire
