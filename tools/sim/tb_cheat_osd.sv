// SPDX-License-Identifier: GPL-2.0-or-later
//
// tb_cheat_osd - parse a .cht, then render a frame of the overlay as text.
//
// Ported from pocket-gg's tools/sim/tb_cheat_osd.sv.
//
// Everything runs on one clock here, which the real core does not do: the parser
// is on clk_sys and the overlay on clk_mem, with cheat_titles as the dual clock
// RAM between them. ce_pix is held high, so one clock is one pixel. What this
// checks is the composition and the geometry, which are clock-independent: that
// the header reads correctly, that the names land on the rows and columns they
// should, and that nothing is drawn in the inset or past the panel.
// tools/sim/run_osd.py reads the picture back and asserts on it.
//
//   +f=<path>   the .cht to load first
//
// DIAG and DIAG_SCALE pass through to cheat_osd. With DIAG set, cd_diag's read
// port is modelled below: a registered read, a distinct letter per cell.

`timescale 1ns / 1ps
`default_nettype none

module tb_cheat_osd #(
    parameter DIAG = 0,
    parameter DIAG_SCALE = 1
);

  localparam W = 256;   // active pixels per line, the narrowest mode
  localparam H = 224;   // active lines
  localparam HB = 48;   // horizontal blanking, only has to exceed the 32 fill
  localparam VB = 3;    // vertical blanking lines

  reg clk = 0;
  reg reset = 1;
  reg wr = 0;
  reg [7:0] data = 8'd0;
  reg de = 0;
  reg v_blank = 1;
  reg show = 1;

  wire        code_wr;
  wire  [4:0] code_index;
  wire [12:0] code_addr;
  wire  [7:0] code_data;
  wire  [5:0] code_total, title_count, group_count;
  wire [19:0] byte_count;
  wire        desc_wr, desc_end;
  wire  [4:0] desc_group, desc_col;
  wire  [5:0] desc_char;

  cheat_loader ldr (
      .clk(clk), .reset(reset), .wr(wr), .data(data),
      .code_wr(code_wr), .code_index(code_index), .code_addr(code_addr),
      .code_data(code_data), .code_total(code_total),
      .desc_wr(desc_wr), .desc_group(desc_group), .desc_col(desc_col),
      .desc_char(desc_char), .desc_end(desc_end),
      .title_count(title_count),
      .group_count(group_count), .byte_count(byte_count)
  );

  wire [4:0] osd_group, osd_col, osd_len;
  wire [5:0] osd_char, font_ch;
  wire [2:0] font_row;
  wire [7:0] font_bits;
  wire       active, ink;

  cheat_titles titles (
      .wr_clk(clk), .wr_reset(reset),
      .wr_en(desc_wr), .wr_group(desc_group), .wr_col(desc_col),
      .wr_char(desc_char), .wr_end(desc_end),
      .rd_clk(clk), .rd_group(osd_group), .rd_col(osd_col),
      .rd_char(osd_char), .rd_len(osd_len)
  );

  cheat_font font (.ch(font_ch), .row(font_row), .bits(font_bits));

  // cd_diag's read: {row, col} in, the character one clock later. Letters
  // A..Z stepping by row and column, spaces outside the 6 x 26 block, so a
  // column read from its neighbour decodes as the wrong letter.
  wire [7:0] diag_raddr;
  reg  [5:0] diag_rchar = 6'd0;
  always @(posedge clk)
    diag_rchar <= (diag_raddr[7:5] < 3'd6 && diag_raddr[4:0] < 5'd26)
                ? 6'd33 + ((diag_raddr[7:5] * 5 + diag_raddr[4:0]) % 26)
                : 6'd0;

  cheat_osd #(.DIAG(DIAG), .DIAG_SCALE(DIAG_SCALE)) osd (
      .clk(clk), .reset(reset),
      .show(show), .ce_pix(1'b1), .de(de), .v_blank(v_blank),
      .title_count(title_count), .code_count(code_total),
      .diag_valid(1'b1), .diag_raddr(diag_raddr), .diag_rchar(diag_rchar),
      .title_group(osd_group), .title_col(osd_col),
      .title_char(osd_char), .title_len(osd_len),
      .font_ch(font_ch), .font_row(font_row), .font_bits(font_bits),
      .active(active), .ink(ink)
  );

  always #5 clk = ~clk;

  integer fd, c, i, x, y;
  reg [8*512:1] fname;
  // Exactly W characters. An earlier W+1 left one uninitialised character at
  // the top of the vector that %0s still prints, which read as a garbage
  // glyph glued to the front of every decoded row.
  reg [8*W:1] row;

  initial begin
    if (!$value$plusargs("f=%s", fname)) begin
      $display("FAIL no +f=<path>");
      $finish;
    end
    fd = $fopen(fname, "rb");
    if (fd == 0) begin
      $display("FAIL cannot open %0s", fname);
      $finish;
    end

    repeat (4) @(posedge clk);
    reset <= 1'b0;
    repeat (2) @(posedge clk);

    // The file, then long enough for every push to drain. cheat_loader needs
    // no end of file: its counts are right after every byte.
    c = $fgetc(fd);
    while (c != -1) begin
      @(posedge clk);
      wr <= 1'b1; data <= c[7:0];
      @(posedge clk);
      wr <= 1'b0;
      repeat (4) @(posedge clk);
      c = $fgetc(fd);
    end
    $fclose(fd);
    repeat (4096) @(posedge clk);

    $display("COUNTS cheats=%0d codes=%0d", title_count, code_total);

    // A frame. Vertical blanking first, which is when the overlay fills the
    // buffer for line zero.
    v_blank <= 1'b1;
    de      <= 1'b0;
    repeat (VB * (W + HB)) @(posedge clk);
    v_blank <= 1'b0;

    for (y = 0; y < H; y = y + 1) begin
      for (x = 1; x <= W; x = x + 1) row[8*x-:8] = " ";
      de <= 1'b1;
      #1;
      // Pixel 0 is sampled here, before any clock edge: de was raised this
      // same instant, so pixel_col/text_col are still whatever blanking left
      // them at (0), which is the state a real display would show for the
      // first active pixel. Sampling after a posedge instead, for every pixel
      // including this one, reads the state one pixel_col tick too far: the
      // first edge under de=1 already advances the counters past 0, so every
      // column read back one pixel of the next.
      row[8*W-:8] = active === 1'bx || ink === 1'bx ? "X"
                  : active ? (ink ? "#" : ".") : " ";
      for (x = 1; x < W; x = x + 1) begin
        @(posedge clk);
        #1;
        // Left to right, so column 0 is the leftmost character of the string.
        // X spelled out rather than left to propagate through a ternary, so an
        // uninitialised cell of the line buffer is visible instead of printing
        // as some bitwise mixture of the two glyph characters.
        if (active === 1'bx || ink === 1'bx) row[8*(W-x)-:8] = "X";
        else row[8*(W-x)-:8] = active ? (ink ? "#" : ".") : " ";
      end
      @(posedge clk);
      de <= 1'b0;
      repeat (HB - 1) @(posedge clk);
      $display("ROW %0d |%0s|", y, row);
    end

    $display("DONE");
    $finish;
  end

endmodule

`default_nettype wire
