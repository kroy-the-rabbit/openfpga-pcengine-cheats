// SPDX-License-Identifier: GPL-3.0-or-later
//
// Draws the names of the loaded cheats over the game picture.
//
// The Pocket menu cannot do this. APF fixes every label in interact.json at
// build time and gives a core no way to put a string on screen, which is why a
// menu can only ever say "Cheat 1", "Cheat 2". The core owns every pixel of
// the game picture, though, so the list goes there instead.
//
//     3 CHEATS 5 CODES
//     INFINITE ENERGY
//     MAX GOLD
//     HAVE BOMBS
//
// Ported from the GB/GBC fork with two simplifications and one real change.
//
// The real change is the pixel clock. The Game Boy core has one pixel per video
// clock, so `de` alone paces the counters. The PC Engine does not: the VCE
// runs 5.37, 7.16 or 10.74 MHz off the same 42.95 MHz clock depending on the
// video mode the game selected, and hands the rest of the core a `ce_pix`
// enable. Every counter here steps on `ce_pix`, and `active`/`ink` are only
// meaningful on those cycles.
//
// The variable resolution that made this look hard turned out not to matter.
// 26 columns at a 6 pixel cell is 156 pixels wide and 18 rows of 8 is 144
// tall, and the narrowest mode this core produces is 256x224. The panel is
// anchored at the top left in the core's own pixel space, before the
// linebuffer, so it fits every mode without knowing which one is running and
// inherits whatever scaling the core does afterwards.
//
// The two simplifications drop code the PC Engine does not need. There is no
// display-list scan, because cheat_loader commits a group's codes only once it
// knows the group is enabled, so every title from 0 to title_count-1 is on and
// the list is already in order. And there is no cartridge/file header row: this
// core loads from the SD card only, so there is nothing to disambiguate.
//
// One thing is still computed ahead of the pixels that need it. Each text row
// needs 26 glyph bytes and each takes a RAM read plus a font lookup; doing that
// per pixel would put a memory on the video path. The line is built during the
// horizontal blanking before it, which is far longer than the 29 cycles needed.
//

`default_nettype none

module cheat_osd #(
    // The glyph is 5 wide inside an 8 wide byte, so a 6 pixel cell still
    // leaves a clear column between letters. Rows stay at 8: the gap under a
    // glyph is what keeps lines apart.
    parameter CELL = 6,
    parameter COLS = 29,   // COL0 + 26 characters
    parameter ROWS = 20,   // ROW0 + header + 17 lines

    // Inset from the top left corner, in cells and rows rather than pixels.
    // Counted in cells because that is what makes it free: the offset is
    // applied when the line buffer is filled, during blanking, instead of to
    // the pixel counters. An earlier version subtracted a pixel offset from py
    // and gated the column counter on px, which put a subtractor and a
    // comparator on the pixel-rate path and cost 1,552 ALMs and 3.4x the fit
    // time for what is a cosmetic offset.
    parameter COL0 = 3,
    parameter ROW0 = 2
) (
    input  wire        clk,          // clk_sys_42_95, the video clock here
    input  wire        reset,

    input  wire        show,         // menu toggle, already on this clock
    input  wire        ce_pix,       // one pixel of the core's picture
    input  wire        de,           // active picture: not h or v blanked
    input  wire        v_blank,

    input  wire [5:0]  title_count,  // enabled groups, from cheat_loader
    input  wire [5:0]  code_count,

    output reg  [4:0]  title_group,  // to cheat_titles
    output reg  [4:0]  title_col,
    input  wire [5:0]  title_char,
    input  wire [4:0]  title_len,

    output wire [5:0]  font_ch,      // to cheat_font
    output wire [2:0]  font_row,
    input  wire [7:0]  font_bits,

    output wire        active,       // this pixel belongs to the overlay
    output wire        ink           // and it is part of a letter
);

  localparam HDR_ROWS  = 1;
  localparam MAX_LINES = ROWS - ROW0 - HDR_ROWS;

  // ------------------------------------------------------------- pixels ----
  reg [8:0] px = 0;
  reg [8:0] py = 0;
  reg       de_d = 0;
  wire      line_end = de_d & ~de;

  always @(posedge clk) begin
    de_d <= de;
    if (reset || v_blank) begin
      px <= 9'd0;
      py <= 9'd0;
    end else begin
      if (ce_pix) px <= de ? px + 9'd1 : 9'd0;
      // py names the line about to be drawn, so the line buffer can be filled
      // during the blanking that precedes it.
      if (line_end) py <= py + 9'd1;
    end
  end

  // Plain slices of py, deliberately. The panel is inset by leaving its first
  // ROW0 rows and COL0 columns empty rather than by moving the raster origin,
  // so nothing here has to do arithmetic at pixel rate.
  wire [4:0] text_row  = py[7:3];
  wire [2:0] glyph_row = py[2:0];

  // 6 does not divide a bit slice, so the column is counted rather than sliced
  // out of px. Both follow px exactly, one step per active pixel.
  //
  // 7 bits, not the 5 the Game Boy version uses. 5 bits wrap at 32, which at a
  // 6 pixel cell is pixel 192, and the narrowest PC Engine mode is 256 wide: the
  // counter would restart mid-line and draw the whole panel a second time. The
  // 160 pixel Game Boy screen ends before that point, so it never had to care.
  // 7 bits reaches 127, which covers 512/6 = 85, the widest mode here.
  reg [6:0] text_col = 0;
  reg [2:0] pixel_col = 0;

  always @(posedge clk) begin
    if (reset || !de) begin
      text_col  <= 7'd0;
      pixel_col <= 3'd0;
    end else if (ce_pix) begin
      if (pixel_col == CELL[2:0] - 3'd1) begin
        pixel_col <= 3'd0;
        text_col  <= text_col + 7'd1;
      end else begin
        pixel_col <= pixel_col + 3'd1;
      end
    end
  end

  // ------------------------------------------------------------- header ----
  // Font indices are ASCII - 32. Spelled out so the header needs no string ROM.
  localparam [5:0] SP = 6'd0,  A = 6'd33, C = 6'd35, D = 6'd36, E = 6'd37,
                   H = 6'd40, L = 6'd44, N = 6'd46, O = 6'd47, S = 6'd51,
                   T = 6'd52;

  function automatic [5:0] digit(input [5:0] v, input tens);
    reg [5:0] t;
    begin
      t = (v >= 6'd60) ? 6'd6 : (v >= 6'd50) ? 6'd5 : (v >= 6'd40) ? 6'd4 :
          (v >= 6'd30) ? 6'd3 : (v >= 6'd20) ? 6'd2 : (v >= 6'd10) ? 6'd1 : 6'd0;
      // A leading zero on a count of four cheats reads as a mistake, so the
      // tens column is blank below ten.
      digit = tens ? (t == 6'd0 ? SP : (6'h10 + t))   // '0' is font index 16
                   : (6'h10 + (v - (t * 6'd10)));
    end
  endfunction

  function automatic [5:0] header_char(input [4:0] col);
    begin
      if (title_count == 6'd0) begin
        // "NO CHEATS LOADED"
        case (col)
          5'd0:  header_char = N;  5'd1:  header_char = O;
          5'd3:  header_char = C;  5'd4:  header_char = H;
          5'd5:  header_char = E;  5'd6:  header_char = A;
          5'd7:  header_char = T;  5'd8:  header_char = S;
          5'd10: header_char = L;  5'd11: header_char = O;
          5'd12: header_char = A;  5'd13: header_char = D;
          5'd14: header_char = E;  5'd15: header_char = D;
          default: header_char = SP;
        endcase
      end else begin
        case (col)
          5'd0:  header_char = digit(title_count, 1'b1);
          5'd1:  header_char = digit(title_count, 1'b0);
          5'd3:  header_char = C;  5'd4:  header_char = H;
          5'd5:  header_char = E;  5'd6:  header_char = A;
          5'd7:  header_char = T;  5'd8:  header_char = S;
          5'd10: header_char = digit(code_count, 1'b1);
          5'd11: header_char = digit(code_count, 1'b0);
          5'd13: header_char = C;  5'd14: header_char = O;
          5'd15: header_char = D;  5'd16: header_char = E;
          5'd17: header_char = S;
          default: header_char = SP;
        endcase
      end
    end
  endfunction

  // --------------------------------------------------------- line buffer ---
  reg [7:0] line_bits [0:COLS-1];
  reg [5:0] fill = 0;              // 0..COLS+2, past the end to drain
  reg       filling = 0;

  // Three stages, because the address is registered here and again inside
  // cheat_titles before its data comes back. The header takes the same three
  // so both halves of a line agree on which column they are drawing.
  reg [4:0] fill_col_d1 = 0, fill_col_d2 = 0, fill_col_d3 = 0;
  reg       fill_hdr_d1 = 0, fill_hdr_d2 = 0, fill_hdr_d3 = 0;
  reg       fill_pre_d1 = 0, fill_pre_d2 = 0, fill_pre_d3 = 0;
  reg [4:0] fill_src_d1 = 0, fill_src_d2 = 0, fill_src_d3 = 0;

  // Which character of the title this cell shows. The first COL0 cells have
  // none, and are blanked by fill_pre rather than by reading somewhere safe.
  wire [4:0] src_col = (fill >= COL0[5:0]) ? (fill[4:0] - COL0[4:0]) : 5'd0;
  reg [5:0] hdr_char_d1 = 0, hdr_char_d2 = 0, hdr_char_d3 = 0;

  // The first ROW0 rows are left blank, which is the vertical half of the inset.
  wire       above     = (text_row < ROW0[4:0]);
  wire       in_header = !above && (text_row < (ROW0[4:0] + HDR_ROWS[4:0]));
  wire [4:0] row_index = text_row - ROW0[4:0] - HDR_ROWS[4:0];
  wire       row_used  = in_header
                      || (!above && text_row >= (ROW0[4:0] + HDR_ROWS[4:0])
                          && row_index < MAX_LINES[4:0]
                          && {1'b0, row_index} < title_count);

  // The fill runs on the full clock, not ce_pix: it has a whole blanking
  // period to do 29 reads and the pixel rate is the slow thing here.
  always @(posedge clk) begin
    if (reset) begin
      filling <= 1'b0;
      fill    <= 6'd0;
    end else if (line_end || (v_blank && !filling && py == 9'd0)) begin
      filling <= 1'b1;
      fill    <= 6'd0;
    end else if (filling) begin
      if (fill > COLS + 2) filling <= 1'b0;
      else                 fill <= fill + 6'd1;
    end

    // Address stage. The destination column is `fill`; the source is COL0
    // cells earlier, so the first COL0 cells of every line come out blank and
    // the text begins inset. Doing it here rather than at the pixel counters
    // is what keeps the offset free: this runs once per column during
    // blanking, not once per pixel.
    title_group <= (row_used && !in_header) ? row_index : 5'd0;
    title_col   <= src_col;
    fill_col_d1 <= fill[4:0];
    fill_hdr_d1 <= in_header;
    fill_pre_d1 <= (fill < COL0[5:0]);
    fill_src_d1 <= src_col;
    hdr_char_d1 <= header_char(src_col);

    // Data stage: the RAM is answering.
    fill_col_d2 <= fill_col_d1;
    fill_hdr_d2 <= fill_hdr_d1;
    fill_pre_d2 <= fill_pre_d1;
    fill_src_d2 <= fill_src_d1;
    hdr_char_d2 <= hdr_char_d1;
    fill_col_d3 <= fill_col_d2;
    fill_hdr_d3 <= fill_hdr_d2;
    fill_pre_d3 <= fill_pre_d2;
    fill_src_d3 <= fill_src_d2;
    hdr_char_d3 <= hdr_char_d2;

    // Write stage: the glyph row is out.
    if (filling && fill >= 6'd3 && fill_col_d3 < COLS[4:0])
      line_bits[fill_col_d3] <= (row_used && !fill_pre_d3) ? font_bits : 8'd0;
  end

  // The title RAM answers two cycles after being asked, so the header is
  // delayed by the same two or the halves of a line disagree about the column.
  wire beyond = !fill_hdr_d3 && (fill_src_d3 >= title_len);
  assign font_ch  = fill_hdr_d3 ? hdr_char_d3 : (beyond ? SP : title_char);
  assign font_row = glyph_row;

  // ------------------------------------------------------------- output ----
  // The sixth pixel of a cell reads bit 2, which is below the 5 wide glyph and
  // therefore always clear: the gap between letters needs no special case.
  // Indexed only inside the panel: past it the column counter runs on to the
  // end of the line and would address off the end of the buffer.
  wire in_panel = (text_col < COLS[6:0]);
  wire [7:0] bits = in_panel ? line_bits[text_col[4:0]] : 8'd0;
  assign active = show && de && row_used && in_panel && (py < (ROWS*8));
  assign ink    = active && bits[3'd7 - pixel_col];

endmodule

`default_nettype wire
