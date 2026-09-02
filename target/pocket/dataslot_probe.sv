// SPDX-License-Identifier: GPL-3.0-or-later
//
// Measures how fast APF hands the core bytes out of a data slot.
//
// `docs/CD-PLAN.md` P0, which this answered: 1104 KB/s at 8KB requests, 6.3x
// CD-DA on its own, no errors. Kept because the number is a property of a card
// and a firmware rather than of this core, so it is worth being able to re-ask
// on a different card.
//
// Method: issue back to back slot reads for exactly one second of clk_74a and
// count the bytes that arrive. One second is chosen so the answer needs no
// divider: bytes counted in a second are the rate. The KB counter is kept in
// packed BCD so the digits can be printed straight out of the nibbles.
//
// Bytes are counted where they land, as bridge writes inside the probe's
// address window, not by adding up the requests that reported success. A host
// that acknowledges a read and delivers nothing is exactly the failure this is
// meant to catch.
//
// Worst case single request latency is tracked alongside the rate, because an
// average that clears the bar still starves a CD-DA ring if one request in a
// hundred stalls. It counts in units of 1024 clk_74a cycles, which is 13.8 us
// at 74.25 MHz. That measurement is the one that shaped the design: the stall
// turned out to be a fixed ~46 ms event independent of request size, so the
// ring is sized against it rather than against the rate.
//
// Nothing here is a feature. It is parameterised off in a shipping build, the
// way DEBUG_WIPE is in cheat_poker: see docs/BASELINE.md.

`default_nettype none

module dataslot_probe #(
    // The slot to read: 101, the bin, which is the only deferload slot and the
    // only one big enough for an 8MB span. It is empty until DEBUG Path Probe
    // has opened a file into it, so run that first or every read returns 2.
    parameter [15:0] SLOT_ID = 16'd101,

    // Bytes per request is chosen at runtime, not here: it is the variable
    // worth sweeping, and a parameter would cost a 19 minute build per value.
    // Measured 2026-09-01: 512 gives 453 KB/s, 2048 gives 694, 8192 gives
    // 1104, against a streaming ceiling near 1221 and a fixed cost of about
    // 0.69 ms per request.
    parameter [31:0] CHUNK0 = 32'd512,
    parameter [31:0] CHUNK1 = 32'd2048,
    parameter [31:0] CHUNK2 = 32'd8192,

    // Offsets wrap inside this much of the file, so the probe keeps seeking
    // rather than walking off the end. The test image must be at least this
    // big or the reads start returning "out of range".
    parameter [31:0] SPAN = 32'h0080_0000,

    // One measurement window.
    parameter [31:0] CLK_HZ = 32'd74_250_000,

    // Where the host is told to put the bytes. Nothing has to answer at this
    // address: unclaimed bridge writes go nowhere, which is why the probe
    // costs no block RAM.
    parameter [31:0] WINDOW = 32'h6000_0000
) (
    input  wire         clk,           // clk_74a, the bridge clock
    input  wire         reset,

    input  wire         start,         // level from the menu, edge detected
    input  wire [  1:0] chunk_sel,     // 0/1/2 pick CHUNK0/1/2, latched per run

    // The bridge, watched rather than driven.
    input  wire [ 31:0] bridge_addr,
    input  wire         bridge_wr,

    // Generic target command port, out to core_bridge_cmd.
    output reg          cmd_req,
    output wire [ 15:0] cmd,
    output reg  [ 31:0] cmd_p0,
    output reg  [ 31:0] cmd_p1,
    output reg  [ 31:0] cmd_p2,
    output reg  [ 31:0] cmd_p3,
    input  wire         cmd_ack,
    input  wire         cmd_done,
    input  wire [ 15:0] cmd_result,

    // The answer, already a line of text: see the comment on diag_line in
    // cheat_osd. Composing it here rather than there keeps every trace of the
    // diagnostic in the module P6 deletes.
    output wire [155:0] line,
    output reg          valid
);

  localparam [15:0] CMD_SLOT_READ = 16'h0180;
  assign cmd = CMD_SLOT_READ;

  // Latched at the start of a run, so turning the menu slider mid-measurement
  // cannot produce a rate that belongs to two different request sizes.
  reg [31:0] run_chunk;
  reg [ 1:0] chunk_ran;

  wire [31:0] chunk_bytes = (chunk_sel == 2'd0) ? CHUNK0 :
                            (chunk_sel == 2'd1) ? CHUNK1 : CHUNK2;

  // Saturating packed BCD increment. Saturating rather than wrapping because a
  // wrapped 99999 reads as a small number, and a rate this probe cannot
  // represent is a pass either way.
  function automatic [19:0] bcd_inc(input [19:0] v);
    begin
      bcd_inc = v;
      if (v[3:0] != 4'd9) bcd_inc[3:0] = v[3:0] + 4'd1;
      else begin
        bcd_inc[3:0] = 4'd0;
        if (v[7:4] != 4'd9) bcd_inc[7:4] = v[7:4] + 4'd1;
        else begin
          bcd_inc[7:4] = 4'd0;
          if (v[11:8] != 4'd9) bcd_inc[11:8] = v[11:8] + 4'd1;
          else begin
            bcd_inc[11:8] = 4'd0;
            if (v[15:12] != 4'd9) bcd_inc[15:12] = v[15:12] + 4'd1;
            else begin
              bcd_inc[15:12] = 4'd0;
              if (v[19:16] != 4'd9) bcd_inc[19:16] = v[19:16] + 4'd1;
              else bcd_inc = v;  // saturate at 99999
            end
          end
        end
      end
    end
  endfunction

  localparam [2:0] ST_IDLE = 3'd0;
  localparam [2:0] ST_ISSUE = 3'd1;
  localparam [2:0] ST_WAIT = 3'd2;
  localparam [2:0] ST_NEXT = 3'd3;
  localparam [2:0] ST_DONE = 3'd4;

  reg [ 2:0] state = ST_IDLE;
  reg        start_d = 0;
  wire       start_rise = start & ~start_d;

  reg [31:0] window;                   // clocks left in the measurement
  reg [ 7:0] wr_count;                 // bridge writes, 256 of them is 1 KB
  reg [19:0] kb_bcd;
  reg [19:0] lat_bcd;
  reg [19:0] lat_cur;                  // this request, in 1024 clock units
  reg [ 9:0] lat_sub;                  // and the clocks inside one unit
  reg [ 2:0] err;
  reg        outstanding;

  // A bridge write inside the window is four bytes of slot data arriving.
  wire byte_pulse = bridge_wr && (bridge_addr[31:24] == WINDOW[31:24]);

  always @(posedge clk) begin
    start_d <= start;

    if (reset) begin
      state       <= ST_IDLE;
      cmd_req     <= 1'b0;
      outstanding <= 1'b0;
      valid       <= 1'b0;
      chunk_ran   <= 2'd0;
      kb_bcd      <= 20'd0;
      lat_bcd     <= 20'd0;
      err         <= 3'd0;
    end else begin

      // ------------------------------------------------------- counters ----
      // Deliberately outside the state machine. The window has to run down on
      // every cycle of the second, including the ones spent waiting on a
      // request, or the rate is measured against the wrong denominator.
      if (state != ST_IDLE && state != ST_DONE) begin
        if (window != 32'd0) window <= window - 32'd1;

        if (byte_pulse) begin
          wr_count <= wr_count + 8'd1;
          if (wr_count == 8'd255) kb_bcd <= bcd_inc(kb_bcd);
        end

        if (outstanding) begin
          if (lat_sub == 10'd1023) begin
            lat_sub <= 10'd0;
            lat_cur <= bcd_inc(lat_cur);
          end else begin
            lat_sub <= lat_sub + 10'd1;
          end
        end
      end

      // ---------------------------------------------------------- states ---
      case (state)
        ST_IDLE: begin
          cmd_req <= 1'b0;
          if (start_rise) begin
            kb_bcd    <= 20'd0;
            lat_bcd   <= 20'd0;
            err       <= 3'd0;
            valid     <= 1'b0;
            window    <= CLK_HZ;
            wr_count  <= 8'd0;
            cmd_p0    <= {16'd0, SLOT_ID};
            cmd_p1    <= 32'd0;          // slot offset
            cmd_p2    <= WINDOW;         // bridge address
            cmd_p3    <= chunk_bytes;    // length
            run_chunk <= chunk_bytes;
            chunk_ran <= chunk_sel;
            state     <= ST_ISSUE;
          end
        end

        ST_ISSUE: begin
          cmd_req     <= 1'b1;
          outstanding <= 1'b1;
          lat_cur     <= 20'd0;
          lat_sub     <= 10'd0;
          state       <= ST_WAIT;
        end

        ST_WAIT: begin
          // core_bridge_cmd holds ack up for the whole transaction, so the
          // request line is dropped as soon as it is seen rather than waiting
          // for the result.
          if (cmd_ack) cmd_req <= 1'b0;

          if (cmd_done) begin
            outstanding <= 1'b0;
            if (cmd_result != 16'd0) err <= cmd_result[2:0];
            // Packed BCD compares correctly as an unsigned integer, so the
            // worst case needs no conversion to find.
            if (lat_cur > lat_bcd) lat_bcd <= lat_cur;
            state <= ST_NEXT;
          end
        end

        ST_NEXT: begin
          // Stop on the first refusal. A run that spent half its second being
          // told the offset is out of range is not a throughput measurement.
          if (err != 3'd0 || window == 32'd0) begin
            state <= ST_DONE;
          end else begin
            cmd_p1 <= (cmd_p1 + run_chunk >= SPAN) ? 32'd0 : cmd_p1 + run_chunk;
            state  <= ST_ISSUE;
          end
        end

        ST_DONE: begin
          cmd_req <= 1'b0;
          valid   <= 1'b1;
          if (!start) state <= ST_IDLE;
        end

        default: state <= ST_IDLE;
      endcase
    end
  end

  // ----------------------------------------------------------- the line ----
  // "KB/S NNNNN LAT NNNNN EN CN", 26 cells, char 0 in the high bits.
  // Font indices are ASCII - 32.
  localparam [5:0] SP = 6'd0, SL = 6'd15, A = 6'd33, B = 6'd34, C = 6'd35,
                   E = 6'd37, K = 6'd43, L = 6'd44, S = 6'd51, T = 6'd52;

  function automatic [5:0] dig(input [3:0] v);
    begin
      dig = 6'h10 + {2'd0, v};
    end
  endfunction

  assign line = {
      K, B, SL, S, SP,
      dig(kb_bcd[19:16]), dig(kb_bcd[15:12]), dig(kb_bcd[11:8]),
      dig(kb_bcd[7:4]), dig(kb_bcd[3:0]), SP,
      L, A, T, SP,
      dig(lat_bcd[19:16]), dig(lat_bcd[15:12]), dig(lat_bcd[11:8]),
      dig(lat_bcd[7:4]), dig(lat_bcd[3:0]), SP,
      E, dig({1'b0, err}), SP,
      C, dig({2'd0, chunk_ran})
  };

endmodule

`default_nettype wire
