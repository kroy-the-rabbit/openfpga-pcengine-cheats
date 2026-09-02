// SPDX-License-Identifier: GPL-3.0-or-later
//
// The diagnostic block, as a small RAM instead of a very wide crossing.
//
// `docs/CD-PLAN.md` P4. The overlay draws six rows of 26 characters and reads
// them one character at a time, and for one build those 936 bits were carried
// into the video clock as a bus: a 937 bit `synch_3`, 2811 registers, dragged
// from one corner of the die to another so that six lines of debug text could
// be drawn. It cost about a nanosecond of setup slack, which was most of what
// the design had.
//
// A character at a time is how the overlay wants it anyway, so the block goes
// into a 256 by 6 dual-clock memory instead: written in the core clock where
// it is composed, read in the video clock where it is drawn. One M10K, and the
// crossing is gone.
//
// The writer walks the whole address space rather than only the 156 cells that
// hold text, filling the rest with spaces. That means the read side never has
// to guard its address, which matters because the overlay's fill counter runs
// past the last column to drain its pipeline and would otherwise index cells
// nobody had written.

`default_nettype none

module cd_diag (
    // ---- write side, where the block is composed ----
    input  wire         clk_sys,
    input  wire [935:0] block,     // six rows of 26, row 0 in the top 156 bits
    input  wire         valid,

    // ---- read side, where it is drawn ----
    input  wire         clk_osd,
    input  wire [  7:0] raddr,     // {row[2:0], col[4:0]}
    output reg  [  5:0] rchar,
    output wire         valid_osd
);

  reg [5:0] mem[0:255];

  // Refreshed continuously: 256 clocks is 6 us, against a source that changes
  // every 95. There is no handshake because there is nothing to miss.
  reg [7:0] wr_addr = 0;

  wire [2:0] wr_row = wr_addr[7:5];
  wire [4:0] wr_col = wr_addr[4:0];

  // Row 0 is the most significant 156 bits so that it draws at the top, and
  // within a row character 0 is the most significant six bits for the same
  // reason.
  wire [9:0] base = ({7'd0, (3'd5 - wr_row)} * 10'd156)
                  + ({5'd0, (5'd25 - wr_col)} * 10'd6);

  wire in_text = (wr_row < 3'd6) && (wr_col < 5'd26);

  always @(posedge clk_sys) begin
    wr_addr <= wr_addr + 8'd1;
    mem[wr_addr] <= in_text ? block[base+:6] : 6'd0;   // font index 0 is space
  end

  always @(posedge clk_osd) rchar <= mem[raddr];

  synch_3 s_valid (valid, valid_osd, clk_osd);

endmodule

`default_nettype wire
