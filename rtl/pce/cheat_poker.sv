// SPDX-License-Identifier: GPL-3.0-or-later
//
// cheat_poker - write cheat values into PC Engine work RAM once a frame
//
// The Game Boy fork this is ported from has two cheat mechanisms and treats the
// ROM read override as the primary one. On the PC Engine that ranking inverts.
// Every one of the 1224 codes in libretro's 397 published .cht files for this
// machine is a RAM poke; not one patches ROM. So this module, not the CODES
// comparator already sitting unwired in pce_top, is the feature.
//
// Mechanically it is the simpler of the two. A poke is what the cheat device
// actually did: stop the CPU at vblank, write the value, let it go. There is no
// approximation to defend the way there is when you fake a read instead, and no
// bank qualifier to check either, because the 8KB at bank $F8 is not banked.
//
// Writes go out through port B of the work RAM dpram, which otherwise belongs
// to the cold-reset clear. The clear wins whenever it wants the port: it runs
// once per load, this runs once per frame, and a poke it swallows is simply
// reissued at the next vblank. `blocked` abandons the walk rather than stalling
// it, for the same reason.
//
// The code table is a small memory, not a register file, so a fresh scan_index
// costs one cycle before the entry is readable. That is what SETTLE is for.
// Keeping the table in MLABs also keeps the per-code lookup off any data path,
// which is the transferable half of the GBC timing lesson in docs/PLAN.md §5.
//
// P1 wiring note: the load port below is idle in this build and the table is
// seeded from the SEED_* parameters at reset, so Quartus folds the memory and
// its write port away. The state machine, the vblank edge detect and the port B
// arbitration are what P1 is proving, and those are all still here.
//

`default_nettype none

module cheat_poker #(
    parameter MAX_CODES = 32,
    parameter INDEX_W   = 5,

    // P1 only. With SEED_EN set, the table is bypassed and the live code comes
    // from the `sel` selector in the body, so a test cheat can be picked from
    // the menu without rebuilding. P2 clears SEED_EN and drives the load port.
    parameter SEED_EN   = 0,

    // Diagnostic, see the `wipe` port. Off in a normal build.
    parameter DEBUG_WIPE = 0,
    parameter [7:0] WIPE_DATA = 8'h00
) (
    input  wire                clk,
    input  wire                reset,
    input  wire                enable,    // master cheat switch
    input  wire                vblank,    // level from the VCE, edge detected here
    input  wire                blocked,   // cold-reset clear owns port B

    // Diagnostic only, and compiled out unless DEBUG_WIPE is set. Sweeps the
    // whole 8KB with a constant instead of walking the table. Its point is to
    // separate "no write reaches work RAM" from "that cheat address is wrong":
    // if this does nothing, the plumbing is dead, and if it wrecks any running
    // game instantly, the plumbing is fine and the cheat is the problem.
    input  wire                wipe,

    // Test-cheat selector, SEED_EN builds only. Indexes the table in the body.
    input  wire  [3:0]         sel,

    // Table load port, driven by cheat_loader in P2.
    input  wire                code_clear,
    input  wire                code_wr,
    input  wire [INDEX_W-1:0]  code_index,
    input  wire [12:0]         code_addr, // offset into the 8KB at bank $F8
    input  wire [7:0]          code_data,
    input  wire                code_live,

    output reg  [INDEX_W:0]    code_count = 0,

    // Work RAM write, in the dpram's port B clock domain.
    // Given explicit power-up values rather than left to the fitter: a poke_wr
    // that comes up asserted writes into work RAM before the cold-reset clear
    // has had a chance to run.
    output wire                poke_wr,
    output wire [12:0]         poke_addr,
    output wire  [7:0]         poke_data
);

  localparam ENTRY_W = 22;  // {live, addr[12:0], data[7:0]}

  localparam [2:0] IDLE = 3'd0, SETTLE = 3'd1, LOOK = 3'd2,
                   WRITE = 3'd3, NEXT = 3'd4;

  reg [ENTRY_W-1:0] tbl       [0:MAX_CODES-1];
  reg [ENTRY_W-1:0] entry = 0;

  reg                f_poke_wr   = 0;
  reg [12:0]         f_poke_addr = 0;
  reg  [7:0]         f_poke_data = 0;

  reg [INDEX_W-1:0] scan_index = 0;
  reg [2:0]         state = IDLE;
  reg               vblank_d = 0;

  wire vblank_rise = vblank & ~vblank_d;

  wire                tbl_we = code_wr;
  wire [INDEX_W-1:0]  tbl_wa = code_index;
  wire [ENTRY_W-1:0]  tbl_wd = {code_live, code_addr, code_data};

  always @(posedge clk) begin
    if (tbl_we) tbl[tbl_wa] <= tbl_wd;
    entry <= tbl[scan_index];
  end

  // Hand-picked test cheats, all taken verbatim from libretro .cht files and
  // all for ROMs that are on the card. Ordered by visibility: the first five
  // are read by gameplay code every frame, so the effect shows the instant the
  // switch flips, with no death to wait for and no HUD-repaint caching to hide
  // it. The lives counters below them are the weaker kind of test and are here
  // only as a fallback.
  reg [12:0] sel_addr;
  reg  [7:0] sel_data;
  reg        sel_live;

  always @(*) begin
    sel_live = 1'b1;
    case (sel)
      4'd1:    begin sel_addr = 13'h1685; sel_data = 8'h03; end // Soldier Blade, max weapon
      4'd2:    begin sel_addr = 13'h16AB; sel_data = 8'hFF; end // Soldier Blade, special bar
      4'd3:    begin sel_addr = 13'h016F; sel_data = 8'h80; end // R-Type, auto fire
      4'd4:    begin sel_addr = 13'h0381; sel_data = 8'h03; end // Blazing Lazers, bombs
      4'd5:    begin sel_addr = 13'h14C5; sel_data = 8'h40; end // Neutopia II, energy
      4'd6:    begin sel_addr = 13'h0142; sel_data = 8'h09; end // R-Type, lives
      4'd7:    begin sel_addr = 13'h037D; sel_data = 8'h02; end // Blazing Lazers, lives
      4'd8:    begin sel_addr = 13'h006F; sel_data = 8'h09; end // Super Star Soldier, lives
      4'd9:    begin sel_addr = 13'h0D8E; sel_data = 8'h09; end // Bomberman, lives
      4'd10:   begin sel_addr = 13'h0DB1; sel_data = 8'h02; end // Bonk's Adventure, lives
      default: begin sel_addr = 13'h0000; sel_data = 8'h00; sel_live = 1'b0; end
    endcase
  end

  wire        entry_live = (SEED_EN != 0) ? sel_live : entry[ENTRY_W-1];
  wire [12:0] entry_addr = (SEED_EN != 0) ? sel_addr : entry[20:8];
  wire  [7:0] entry_data = (SEED_EN != 0) ? sel_data : entry[7:0];

  // Entries at or past code_count were never loaded, so the table needs no
  // clearing walk; the count is the authority on how far a scan goes.
  wire [INDEX_W:0] last_index = (code_count == 0) ? {(INDEX_W+1){1'b0}}
                                                 : code_count - 1'b1;

  always @(posedge clk) begin
    if (reset) begin
      state      <= IDLE;
      scan_index <= {INDEX_W{1'b0}};
      f_poke_wr   <= 1'b0;
      f_poke_addr <= 13'd0;
      f_poke_data <= 8'd0;
      vblank_d   <= 1'b0;
      code_count <= (SEED_EN != 0) ? {{INDEX_W{1'b0}}, 1'b1} : {(INDEX_W+1){1'b0}};
    end else begin
      vblank_d <= vblank;
      f_poke_wr <= 1'b0;

      if (code_clear) code_count <= {(INDEX_W+1){1'b0}};
      else if (code_wr && ({1'b0, code_index} >= code_count))
        code_count <= {1'b0, code_index} + 1'b1;

      if (blocked || !enable || code_count == 0) begin
        // hand the port back at once; the walk restarts at the next vblank
        state <= IDLE;
      end else begin
        case (state)
          IDLE:
          if (vblank_rise) begin
            scan_index <= {INDEX_W{1'b0}};
            state      <= SETTLE;
          end

          SETTLE: state <= LOOK;

          LOOK:
          if (entry_live) begin
            f_poke_addr <= entry_addr;
            f_poke_data <= entry_data;
            f_poke_wr   <= 1'b1;
            state     <= WRITE;
          end else begin
            state <= NEXT;
          end

          WRITE: state <= NEXT;

          NEXT:
          if ({1'b0, scan_index} >= last_index) begin
            state <= IDLE;
          end else begin
            scan_index <= scan_index + 1'b1;
            state      <= SETTLE;
          end

          default: state <= IDLE;
        endcase
      end
    end
  end

  // ------------------------------------------------------------------
  // Diagnostic wipe. Walks all 8KB writing a constant, continuously, using
  // exactly the same output path the real poker uses. Nothing about it is
  // subtle: if a port B write reaches work RAM at all, turning this on
  // destroys whatever game is running within a frame.
  // ------------------------------------------------------------------
  reg         w_poke_wr   = 0;
  reg  [12:0] w_poke_addr = 0;

  generate
    if (DEBUG_WIPE != 0) begin : g_wipe
      always @(posedge clk) begin
        if (reset) begin
          w_poke_wr   <= 1'b0;
          w_poke_addr <= 13'd0;
        end else if (wipe && !blocked) begin
          w_poke_wr   <= 1'b1;
          w_poke_addr <= w_poke_addr + 1'b1;
        end else begin
          w_poke_wr <= 1'b0;
        end
      end
    end
  endgenerate

  wire wiping = (DEBUG_WIPE != 0) && wipe;

  assign poke_wr   = wiping ? w_poke_wr   : f_poke_wr;
  assign poke_addr = wiping ? w_poke_addr : f_poke_addr;
  assign poke_data = wiping ? WIPE_DATA   : f_poke_data;

endmodule

`default_nettype wire
