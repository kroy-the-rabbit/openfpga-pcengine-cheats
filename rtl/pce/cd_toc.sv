// SPDX-License-Identifier: GPL-3.0-or-later
//
// Parses a CD cue sheet into a track table.
//
// `docs/CD-PLAN.md` P2. Built the way `cheat_loader.sv` was, and for the same
// reason: a text file arrives byte by byte through a data slot and has to
// become a structure the rest of the core can index. The techniques are that
// module's, down to the whole-length keyword match.
//
// What a drive needs per track, and all this produces:
//
//   start LBA     where the track begins on the disc, from INDEX 01
//   byte offset   where its data begins in the bin
//   sector size   2048 or 2352, from the TRACK line
//   audio flag    AUDIO rather than MODE1/MODE2
//
// **There is no end-of-file signal.** `data_loader` does not provide one, so
// the table has to be correct after every byte rather than completed by a
// final pass. Each track is written the moment its INDEX 01 is read, and
// `track_count` is republished from the same place, so the two cannot drift.
//
// ---- the offset recurrence, and why PREGAP is not in it ----
//
//   base(k+1) = base(k) + (lba(k+1) - lba(k)) * size(k)
//
// A cue's PREGAP conventionally describes silence that is generated rather
// than stored, which would mean subtracting it from the span. **For the images
// this core is documented to take, that is wrong.** `chdman extractcd` writes
// the whole disc, pregaps included, and states them in the cue only to
// describe the structure.
//
// Checked against the real thing rather than reasoned about, because the two
// models differ by a few hundred KB and both look plausible. Rondo's bin is
// 512,871,728 bytes across 22 tracks with pregaps on 2, 3 and 22:
//
//   subtracting pregaps   remainder 21,845,600 = 10666.8 sectors of 2048
//   ignoring pregaps      remainder 20,480,000 = 10000.0 sectors of 2048
//
// A whole number of sectors for the last track is only possible one way. So
// PREGAP is not parsed at all here, and a cue whose bin genuinely omits its
// pregaps would need the other model. Nothing detects which convention a file
// follows; the slot's size would, since the totals differ, and that is the
// place to add it if a redump-style image ever has to work.

`default_nettype none

module cd_toc #(
    parameter MAX_TRACKS = 99
) (
    input  wire        clk,
    input  wire        reset,

    // Byte stream, one byte per asserted cycle. No handshake and no
    // backpressure, exactly as cheat_loader takes it.
    input  wire        wr,
    input  wire [ 7:0] data,

    // Table read port, for the drive model.
    input  wire [ 6:0] rd_track,          // 1-based, as the disc numbers them
    output wire [31:0] rd_lba,
    output wire [31:0] rd_base,
    output wire [11:0] rd_size,
    output wire        rd_audio,

    output reg  [ 6:0] track_count = 0,
    output reg  [31:0] toc_end = 0,       // LBA just past the last track read

    // Diagnostic line, composed here so every trace of it lives in one file.
    // "TRACKS nn LAST xxxxxxxx": the track count, and the byte offset of
    // whichever track rd_track selects, **read back out of the table** rather
    // than from a spare register. Reading it is what makes the memories exist:
    // with the read port unconnected Quartus removed all three, and the build
    // proved the arithmetic while proving nothing about the storage.
    output wire [155:0] line,
    output wire         line_valid
);

  reg [31:0] last_base = 0;

  // ------------------------------------------------------------- storage ---
  // Three memories, each with one writer and one reader. Deliberately not one
  // wide array: a memory with more than one writer is a memory Quartus may
  // decline to infer, and it does not warn when it builds flip-flops instead.
  // See docs/CD-PLAN.md, the inference trap in P1.
  reg [31:0] lba_mem [0:MAX_TRACKS-1];
  reg [31:0] base_mem[0:MAX_TRACKS-1];
  reg [12:0] att_mem [0:MAX_TRACKS-1];   // {audio, sector size}

  reg [31:0] lba_q, base_q;
  reg [12:0] att_q;
  reg [ 6:0] wr_idx;
  reg [31:0] wr_lba, wr_base;
  reg [12:0] wr_att;
  reg        toc_we;

  // rd_track is 1-based and the arrays are 0-based. A read of track 0 lands on
  // index 127, outside the table, and returns whatever is there: the drive
  // model must not ask for track 0.
  wire [6:0] rd_idx = rd_track - 7'd1;

  always @(posedge clk) begin
    if (toc_we) lba_mem[wr_idx] <= wr_lba;
    lba_q <= lba_mem[rd_idx];
  end
  always @(posedge clk) begin
    if (toc_we) base_mem[wr_idx] <= wr_base;
    base_q <= base_mem[rd_idx];
  end
  always @(posedge clk) begin
    if (toc_we) att_mem[wr_idx] <= wr_att;
    att_q <= att_mem[rd_idx];
  end

  assign rd_lba   = lba_q;
  assign rd_base  = base_q;
  assign rd_size  = att_q[11:0];
  assign rd_audio = att_q[12];

  // ---------------------------------------------------- character classes ---
  wire is_eol   = (data == 8'h0A) || (data == 8'h0D);
  wire is_space = (data == 8'h20) || (data == 8'h09);
  wire is_digit = (data >= "0") && (data <= "9");
  wire [3:0] dig = data[3:0];

  // ------------------------------------------------------------ keywords ---
  // FILE, TRACK and INDEX. Everything else a cue can hold, REM and CATALOG and
  // PERFORMER and TITLE and ISRC and FLAGS and POSTGAP, falls into S_SKIP for
  // free, which is the same trick that lets cheat_loader ignore most of a .cht.
  //
  // PREGAP is deliberately among them: see the header.
  localparam [1:0] K_FILE = 2'd0, K_TRACK = 2'd1, K_INDEX = 2'd2;

  function automatic [7:0] kc(input [1:0] k, input [2:0] p);
    reg [39:0] s;
    begin
      case (k)
        K_FILE:  s = {"FILE", 8'd0};
        K_TRACK: s = "TRACK";
        default: s = "INDEX";
      endcase
      kc = s[39 - 8 * p -: 8];
    end
  endfunction

  function automatic [2:0] klen(input [1:0] k);
    begin
      klen = (k == K_FILE) ? 3'd4 : 3'd5;
    end
  endfunction

  reg [2:0] key_ok;
  reg [2:0] key_pos;

  // ------------------------------------------------------------- states ----
  localparam [3:0] S_SOL      = 4'd0;   // start of line, skipping indent
  localparam [3:0] S_KEY      = 4'd1;   // matching the keyword
  localparam [3:0] S_SKIP     = 4'd2;   // discard to end of line
  localparam [3:0] S_TRK_SP   = 4'd3;   // spaces before the track number
  localparam [3:0] S_TRK_NUM  = 4'd4;
  localparam [3:0] S_TRK_SP2  = 4'd5;   // spaces before the mode
  localparam [3:0] S_TRK_MODE = 4'd6;   // AUDIO or MODEn/nnnn
  localparam [3:0] S_TRK_SIZE = 4'd7;   // the digits after the slash
  localparam [3:0] S_IDX_SP   = 4'd8;
  localparam [3:0] S_IDX_NUM  = 4'd9;
  localparam [3:0] S_IDX_SP2  = 4'd10;
  localparam [3:0] S_IDX_M    = 4'd11;
  localparam [3:0] S_IDX_S    = 4'd12;
  localparam [3:0] S_IDX_F    = 4'd13;

  reg [3:0] state = S_SOL;

  reg [ 6:0] trk_num;
  reg [11:0] sec_size;
  reg        is_audio;
  reg        trk_open;              // a TRACK line has been read, awaiting INDEX 01
  reg [ 6:0] idx_num;
  reg [ 6:0] msf_m;
  reg [ 6:0] msf_s;
  reg [ 6:0] msf_f;

  reg [31:0] prev_lba;
  reg [31:0] prev_base;
  reg [11:0] prev_size;
  reg        have_prev;

  // The frames field as it stands including the digit arriving this cycle, so
  // an entry can be committed on every digit rather than on a terminator that
  // a file is not obliged to have. See the commit sequencer below.
  wire [ 6:0] f_next = msf_f * 7'd10 + {3'd0, dig};

  wire        commit_ok = (idx_num == 7'd1) && trk_open
                        && (trk_num >= 7'd1) && (trk_num <= MAX_TRACKS[6:0]);

  // ---- the commit sequencer, and why it is not one expression -------------
  //
  // The first version computed all of this combinationally from the incoming
  // byte: f_next, then MSF to LBA through two multiplies, then a 32 bit
  // subtract, then a 32 by 12 multiply, then an add, then a mux, and only then
  // a register. That is `docs/PLAN.md` section 5 exactly, a long chain hung off
  // late-arriving data, and it cost 5.4 ns: clk_sys_42_95 fell from 42.97 MHz
  // to an Fmax of 35.99 MHz and the build was refused.
  //
  // Spreading it over four cycles costs nothing real. data_loader delivers a
  // byte roughly every ten cycles of this clock, so the sequencer is always
  // idle again before the next one arrives, and every stage now sits between
  // two registers with one operation in it.
  localparam [1:0] C_IDLE = 2'd0, C_SPAN = 2'd1, C_BASE = 2'd2, C_WRITE = 2'd3;

  reg [ 1:0] cstate = C_IDLE;
  reg        c_pend;
  reg        c_promote;
  reg [ 6:0] c_trk;
  reg [12:0] c_att;
  reg [31:0] c_lba, c_span, c_base;

  // Off the registered MSF fields, so `data` is not in this path at all.
  wire [31:0] lba_now = ({25'd0, msf_m} * 32'd60 + {25'd0, msf_s}) * 32'd75
                      + {25'd0, msf_f};

  // One always block, not two. An earlier split had the parser set c_pend and
  // the sequencer clear it, which is two drivers on one register and which
  // Quartus refuses outright: "Can't resolve multiple constant drivers".
  // Merged, the ordering also states the priority: the sequencer runs first and
  // the parser second, so a request raised on the same cycle one is consumed
  // survives rather than being lost.
  always @(posedge clk) begin
    toc_we <= 1'b0;

    if (reset) begin
      state     <= S_SOL;
      c_pend    <= 1'b0;
      c_promote <= 1'b0;
      trk_open  <= 1'b0;
      sec_size  <= 12'd2352;
      is_audio  <= 1'b0;
      trk_num   <= 7'd0;
      cstate    <= C_IDLE;
      prev_lba  <= 32'd0;
      prev_base <= 32'd0;
      prev_size <= 12'd0;
      have_prev <= 1'b0;
      last_base <= 32'd0;
    end else begin
      // Every cycle, because a file that ends on its last digit still has a
      // commit to finish and there is no end-of-file byte to carry it.
        case (cstate)
          C_IDLE: begin
            if (c_pend) begin
              c_pend <= 1'b0;
              c_lba  <= lba_now;
              cstate <= C_SPAN;
            end else if (c_promote) begin
              // Promotion waits for the commit to land, so prev_* can never be
              // taken from a half-written entry. It only has to hold the state
              // before the current track: each digit recomputes that track from
              // prev_*, so promoting early would accumulate onto its own answer.
              c_promote <= 1'b0;
              prev_lba  <= wr_lba;
              prev_base <= wr_base;
              prev_size <= wr_att[11:0];
              have_prev <= 1'b1;
            end
          end
          C_SPAN: begin
            c_span <= c_lba - prev_lba;
            cstate <= C_BASE;
          end
          C_BASE: begin
            c_base <= prev_base + c_span * {20'd0, prev_size};
            cstate <= C_WRITE;
          end
          C_WRITE: begin
            wr_idx  <= c_trk - 7'd1;
            wr_lba  <= c_lba;
            wr_base <= have_prev ? c_base : 32'd0;
            wr_att  <= c_att;
            toc_we  <= 1'b1;

            if (c_trk > track_count) track_count <= c_trk;
            toc_end   <= c_lba;
            last_base <= have_prev ? c_base : 32'd0;
            cstate    <= C_IDLE;
          end
        endcase

      if (wr) begin
        case (state)

          S_SOL: begin
            key_ok  <= 3'b111;
            key_pos <= 3'd0;
            if (is_space || is_eol) state <= S_SOL;
            else begin
              // First character, matched here so S_KEY only ever sees the rest.
              key_ok[K_FILE]  <= (data == kc(K_FILE, 3'd0));
              key_ok[K_TRACK] <= (data == kc(K_TRACK, 3'd0));
              key_ok[K_INDEX] <= (data == kc(K_INDEX, 3'd0));
              key_pos <= 3'd1;
              state   <= S_KEY;
            end
          end

          S_KEY: begin
            if (is_eol) state <= S_SOL;
            else if (is_space) begin
              // A keyword ends only at its own length. Matching a prefix is what
              // made cheat_loader read the wrong field and look like it worked.
              if (key_ok[K_TRACK] && key_pos == klen(K_TRACK)) state <= S_TRK_SP;
              else if (key_ok[K_INDEX] && key_pos == klen(K_INDEX)) state <= S_IDX_SP;
              else state <= S_SKIP;   // FILE and everything else
            end else begin
              if (key_pos >= klen(K_FILE)  || data != kc(K_FILE, key_pos))
                key_ok[K_FILE] <= 1'b0;
              if (key_pos >= klen(K_TRACK) || data != kc(K_TRACK, key_pos))
                key_ok[K_TRACK] <= 1'b0;
              if (key_pos >= klen(K_INDEX) || data != kc(K_INDEX, key_pos))
                key_ok[K_INDEX] <= 1'b0;
              key_pos <= key_pos + 3'd1;
              if (key_pos == 3'd5) state <= S_SKIP;   // longer than any keyword
            end
          end

          S_SKIP: if (is_eol) state <= S_SOL;

          // ---- TRACK nn MODE ----
          S_TRK_SP: begin
            if (is_eol) state <= S_SOL;
            else if (is_digit) begin
              trk_num <= {3'd0, dig};
              state   <= S_TRK_NUM;
            end else if (!is_space) state <= S_SKIP;
          end
          S_TRK_NUM: begin
            if (is_digit) trk_num <= trk_num * 7'd10 + {3'd0, dig};
            else if (is_space) state <= S_TRK_SP2;
            else if (is_eol) state <= S_SOL;
            else state <= S_SKIP;
          end
          S_TRK_SP2: begin
            if (is_eol) state <= S_SOL;
            else if (!is_space) begin
              // AUDIO or MODEn/nnnn, and the first letter is enough to tell.
              // A track with no slash keeps the 2352 default, which is what an
              // audio track is.
              is_audio <= (data == "A");
              sec_size <= 12'd2352;
              state    <= S_TRK_MODE;
            end
          end
          S_TRK_MODE: begin
            if (is_eol) begin
              trk_open <= 1'b1;
              state    <= S_SOL;
            end else if (data == "/") begin
              sec_size <= 12'd0;
              state    <= S_TRK_SIZE;
            end else if (is_space) begin
              trk_open <= 1'b1;
              state    <= S_SKIP;
            end
          end
          S_TRK_SIZE: begin
            if (is_digit) sec_size <= sec_size * 12'd10 + {8'd0, dig};
            else if (is_eol) begin
              trk_open <= 1'b1;
              state    <= S_SOL;
            end else begin
              trk_open <= 1'b1;
              state    <= S_SKIP;
            end
          end

          // ---- INDEX nn mm:ss:ff ----
          S_IDX_SP: begin
            if (is_eol) state <= S_SOL;
            else if (is_digit) begin
              idx_num <= {3'd0, dig};
              state   <= S_IDX_NUM;
            end else if (!is_space) state <= S_SKIP;
          end
          S_IDX_NUM: begin
            if (is_digit) idx_num <= idx_num * 7'd10 + {3'd0, dig};
            else if (is_space) begin
              msf_m <= 7'd0;
              state <= S_IDX_SP2;
            end else if (is_eol) state <= S_SOL;
            else state <= S_SKIP;
          end
          S_IDX_SP2: begin
            if (is_eol) state <= S_SOL;
            else if (is_digit) begin
              msf_m <= {3'd0, dig};
              msf_s <= 7'd0;
              msf_f <= 7'd0;
              state <= S_IDX_M;
            end else if (!is_space) state <= S_SKIP;
          end
          S_IDX_M: begin
            if (is_digit) msf_m <= msf_m * 7'd10 + {3'd0, dig};
            else if (data == ":") state <= S_IDX_S;
            else state <= is_eol ? S_SOL : S_SKIP;
          end
          S_IDX_S: begin
            if (is_digit) msf_s <= msf_s * 7'd10 + {3'd0, dig};
            else if (data == ":") state <= S_IDX_F;
            else state <= is_eol ? S_SOL : S_SKIP;
          end
          S_IDX_F: begin
            if (is_digit) begin
              msf_f <= f_next;
              // Committed on every digit, not on the terminator. There is no
              // end-of-file signal and a cue is not obliged to end with a
              // newline: `INDEX 01 03:04:14<EOF>` would otherwise leave its
              // track missing entirely, which a real file caught in simulation.
              // Each digit rewrites the same entry with a better answer and the
              // last one stands.
              if (commit_ok) begin
                c_pend <= 1'b1;
                c_trk  <= trk_num;
                c_att  <= {is_audio, sec_size};
              end
            end else begin
              // The line is over, so this track is final and becomes the basis
              // for the next one's offset. Promotion is deliberately not done
              // per digit: prev_* must stay the state *before* this track or
              // each digit would accumulate onto the last one's answer.
              //
              // A file that ends mid-number never reaches here, and does not
              // need to: there is no following track for prev_* to serve.
              if (commit_ok) begin
                c_promote <= 1'b1;
                trk_open  <= 1'b0;
              end
              state <= is_eol ? S_SOL : S_SKIP;
            end
          end

          default: state <= S_SOL;
        endcase
      end
    end
  end

  // Four cycles per commit, each stage one operation between two registers.
  // Runs on the clock rather than on `wr`, so a file that ends immediately
  // after its last digit still finishes committing: there is no end-of-file
  // signal to wait for and none is needed.

  // ----------------------------------------------------------- the line ----
  // Font indices are ASCII - 32, matching cheat_font.
  localparam [5:0] SP = 6'd0, A = 6'd33, C = 6'd35, K = 6'd43, L = 6'd44,
                   R = 6'd50, S = 6'd51, T = 6'd52;

  function automatic [5:0] hex(input [3:0] v);
    begin
      hex = (v < 4'd10) ? (6'h10 + {2'd0, v}) : (6'd33 + {2'd0, v} - 6'd10);
    end
  endfunction

  // Decimal, two digits, blank rather than a leading zero. A comparison chain
  // rather than / and %, which would put a real divider in the design for two
  // digits of a diagnostic. cheat_osd's digit() does the same for the same
  // reason.
  function automatic [3:0] tens_of(input [6:0] v);
    begin
      tens_of = (v >= 7'd90) ? 4'd9 : (v >= 7'd80) ? 4'd8 : (v >= 7'd70) ? 4'd7 :
                (v >= 7'd60) ? 4'd6 : (v >= 7'd50) ? 4'd5 : (v >= 7'd40) ? 4'd4 :
                (v >= 7'd30) ? 4'd3 : (v >= 7'd20) ? 4'd2 : (v >= 7'd10) ? 4'd1 :
                4'd0;
    end
  endfunction

  wire [3:0] tc_tens = tens_of(track_count);
  wire [6:0] tc_rem  = track_count - ({3'd0, tc_tens} * 7'd10);
  wire [3:0] tc_ones = tc_rem[3:0];

  assign line_valid = (track_count != 7'd0);
  assign line = {
      T, R, A, C, K, S, SP,
      (tc_tens == 4'd0) ? SP : hex(tc_tens), hex(tc_ones), SP,
      L, A, S, T, SP,
      hex(base_q[31:28]), hex(base_q[27:24]),
      hex(base_q[23:20]), hex(base_q[19:16]),
      hex(base_q[15:12]), hex(base_q[11:8]),
      hex(base_q[7:4]),   hex(base_q[3:0]),
      SP, SP, SP
  };

endmodule

`default_nettype wire
