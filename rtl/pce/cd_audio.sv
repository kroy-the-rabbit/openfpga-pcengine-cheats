// SPDX-License-Identifier: GPL-3.0-or-later
//
// CD-DA: a ring of the bin, drained into cd.vhd at 44.1 kHz.
//
// `docs/CD-PLAN.md` P4. The drive model answers SAPSP and SAPEP and knows
// where the audio lives; this is the part that actually moves the bytes.
//
// ---- why it paces itself ----
//
// `cd.vhd` packs four bytes into a 32 bit word and pushes it into CDDA_FIFO,
// which it drains one word per CDDA_CE, about 44.1 kHz. `FIFO_FULL` guards the
// write and is **not brought out of the module**, so an overrun is not an
// error this can see: the word is dropped and the sound loses a sample with
// nothing to say so.
//
// So the write side runs its own 44.1 kHz tick, generated the same way CEGen
// generates the read side's, from the same clock. Feeding one word per tick
// against a drain of one word per tick means the FIFO sits wherever it started
// and neither end has to know about the other.
//
// ---- the byte order is already right ----
//
// cd.vhd puts byte 0 at FIFO_D[7:0] and reads FIFO_Q[15:0] as left, so a
// stereo frame wants L-low, L-high, R-low, R-high. That is what Redbook stores
// and what is in the bin, so the sectors stream out verbatim: no swapping, no
// sign fixing, no deinterleaving.
//
// ---- the ring ----
//
// Eight chunks of 2048 bytes. 16KB is 93 ms of audio, against a worst case
// stall of about one sector fetch when a data read has the transport. The
// chunk is the unit of everything: the APF writes one chunk per command,
// straight into the ring at the write pointer, so there is no copy.
//
// Chunk counters cross between the clocks rather than byte pointers, and they
// are Gray coded. A chunk counter changes once per 11.6 ms and by one, which
// is what makes Gray worth having; a byte pointer moves by 512 at a time and
// Gray would buy nothing.

`default_nettype none

module cd_audio #(
    parameter [15:0] SLOT_ID = 16'd101,

    // Its own bridge window. 0x60 is the throughput probe, 0x61 the path
    // prober's struct RAM, 0x62 the sector fetcher.
    parameter [31:0] WINDOW = 32'h6300_0000,

    parameter [31:0] CHUNK  = 32'd2048
) (
    input  wire        clk_74a,
    input  wire        clk_sys,
    input  wire        reset,

    // ---- control, in clk_sys ----
    input  wire        play,        // level: stream while high
    input  wire        restart,     // pulse: begin again from start_off
    input  wire [31:0] start_off,   // byte offset of the first sample
    input  wire [31:0] end_off,     // byte offset one past the last
    output reg         ended,       // level: reached end_off

    // ---- to cd.vhd, in clk_sys. cd_host owns the shared data bus. ----
    output reg  [ 7:0] aud_data,
    output reg         aud_req,     // one clock per byte
    output reg         aud_busy,    // the SCSI push stands off while high
    output reg         aud_dm,      // one clock, resets cd.vhd's byte counter

    // ---- the bridge, watched ----
    input  wire [31:0] bridge_addr,
    input  wire        bridge_wr,
    input  wire [31:0] bridge_wr_data,

    // ---- the shared target command port ----
    output reg         cmd_req,
    output wire [15:0] cmd,
    output reg  [31:0] cmd_p0,
    output reg  [31:0] cmd_p1,
    output reg  [31:0] cmd_p2,
    output reg  [31:0] cmd_p3,
    input  wire        cmd_ack,
    input  wire        cmd_done,
    input  wire [15:0] cmd_result,

    output wire [ 3:0] level,       // chunks buffered, for the overlay
    output wire [ 3:0] dbg_wr,      // the two pointers, not just their gap
    output wire [ 3:0] dbg_rd,
    output reg  [31:0] dbg_head,    // first frame drained after a restart
    output reg  [ 3:0] err
);

  assign cmd = 16'h0180;            // data slot read

  localparam CHUNK_WORDS = 9'd512;  // 2048 bytes

  // ---- the ring ----------------------------------------------------------
  // 4096 words of 32 bits, one writer on the bridge clock and one reader on
  // the core clock. Thirteen M10K.
  reg [31:0] mem[0:4095];
  reg [31:0] rq;

  wire win_hit = bridge_wr && (bridge_addr[31:24] == WINDOW[31:24]);

  // ---- chunk pointers ----------------------------------------------------
  // Four bits for eight chunks: the extra bit is what tells full from empty.
  reg  [3:0] wr_chunk = 0;          // clk_74a
  reg  [3:0] rd_chunk = 0;          // clk_sys

  function automatic [3:0] to_gray(input [3:0] v);
    begin
      to_gray = v ^ {1'b0, v[3:1]};
    end
  endfunction

  function automatic [3:0] from_gray(input [3:0] g);
    begin
      from_gray[3] = g[3];
      from_gray[2] = g[3] ^ g[2];
      from_gray[1] = g[3] ^ g[2] ^ g[1];
      from_gray[0] = g[3] ^ g[2] ^ g[1] ^ g[0];
    end
  endfunction

  wire [3:0] wr_gray_sys, rd_gray_74;
  synch_3 #(.WIDTH(4)) s_wr (to_gray(wr_chunk), wr_gray_sys, clk_sys);
  synch_3 #(.WIDTH(4)) s_rd (to_gray(rd_chunk), rd_gray_74,  clk_74a);

  wire [3:0] wr_in_sys = from_gray(wr_gray_sys);
  wire [3:0] rd_in_74  = from_gray(rd_gray_74);

  wire [3:0] used_74  = wr_chunk - rd_in_74;      // chunks the writer has filled
  wire [3:0] used_sys = wr_in_sys - rd_chunk;
  assign level = used_sys;

  wire have_data = (used_sys != 4'd0);

  assign dbg_wr = wr_in_sys;
  assign dbg_rd = rd_chunk;
  wire have_room = (used_74 < 4'd8);

  // ---- restart, crossed into the bridge clock ----------------------------
  // `restart` is a clk_sys pulse and the fetcher lives in clk_74a. A toggle
  // crosses it: a pulse would be missed or seen twice across a slower clock.
  reg  restart_tog = 0;
  always @(posedge clk_sys) if (restart) restart_tog <= ~restart_tog;

  wire restart_tog_74;
  synch_3 s_rst (restart_tog, restart_tog_74, clk_74a);
  reg  restart_tog_74_d = 0;
  wire restart_74 = restart_tog_74 ^ restart_tog_74_d;

  // ...and acknowledged back, because the two sides zero their pointers at
  // different times. Between the reader zeroing its own and the writer hearing
  // about it, the difference of the two still reads as chunks available, and
  // those chunks hold the previous track. The reader therefore waits to be
  // told the writer has restarted rather than inferring it from a count.
  reg  rst_ack_tog = 0;
  wire rst_ack_sys;
  synch_3 s_ack (rst_ack_tog, rst_ack_sys, clk_sys);
  reg  rst_ack_sys_d = 0;
  reg  priming = 1'b1;

  // `start_off` is written before `restart` and does not change until the next
  // one, so it settles long before the toggle arrives and crosses by
  // construction rather than by luck. Same argument cd_fetch's offset uses.
  reg [31:0] fetch_at;              // next byte offset to read, clk_74a

  // ---- the fetcher, in clk_74a -------------------------------------------
  localparam [1:0] A_IDLE = 2'd0, A_ISSUE = 2'd1, A_WAIT = 2'd2;
  reg [1:0] astate = A_IDLE;
  reg       rst_pend = 1'b0;

  always @(posedge clk_74a) begin
    restart_tog_74_d <= restart_tog_74;

    if (win_hit) mem[bridge_addr[13:2]] <= bridge_wr_data;

    if (reset) begin
      astate   <= A_IDLE;
      cmd_req  <= 1'b0;
      wr_chunk <= 4'd0;
      err      <= 4'd0;
      rst_pend <= 1'b0;
    end else begin
      // A restart is recorded here and applied below, never taken mid
      // transaction. This module is filling the ring almost continuously, so
      // SAPSP nearly always lands while a read is in flight; abandoning it
      // between `cmd_ack` and `cmd_done` throws the completion away, and the
      // next read then waits in A_WAIT for a `done` that has already been and
      // gone. The fetcher stops dead on the first SAPSP, which is what an
      // empty ring with the drive reporting DS_PLAY looks like.
      if (restart_74) rst_pend <= 1'b1;

      if (rst_pend && astate == A_IDLE) begin
        rst_pend    <= 1'b0;
        wr_chunk    <= 4'd0;
        fetch_at    <= start_off & ~32'd511;
        rst_ack_tog <= ~rst_ack_tog;
      end else
      case (astate)
        A_IDLE:
          if (have_room) begin
            cmd_p0 <= {16'd0, SLOT_ID};
            cmd_p1 <= fetch_at;
            // Straight into the ring at the write pointer, so nothing is
            // copied afterwards.
            cmd_p2 <= WINDOW | {18'd0, wr_chunk[2:0], 11'd0};
            cmd_p3 <= CHUNK;
            astate <= A_ISSUE;
          end

        A_ISSUE: begin
          cmd_req <= 1'b1;
          astate  <= A_WAIT;
        end

        A_WAIT: begin
          if (cmd_ack) cmd_req <= 1'b0;
          if (cmd_done) begin
            if (cmd_result != 16'd0) err <= cmd_result[3:0];
            fetch_at <= fetch_at + CHUNK;
            wr_chunk <= wr_chunk + 4'd1;
            astate   <= A_IDLE;
          end
        end

        default: astate <= A_IDLE;
      endcase
    end
  end

  // ---- the 44.1 kHz tick -------------------------------------------------
  // The same accumulator CEGen runs for the read side, with the same two
  // constants, so the two ends agree exactly rather than approximately.
  reg [19:0] ce_acc = 0;
  reg        ce_441 = 0;
  always @(posedge clk_sys) begin
    ce_441 <= 1'b0;
    if (ce_acc + 20'd441 >= 20'd429545) begin
      ce_acc <= ce_acc + 20'd441 - 20'd429545;
      ce_441 <= 1'b1;
    end else begin
      ce_acc <= ce_acc + 20'd441;
    end
  end

  // ---- the drain, in clk_sys ---------------------------------------------
  // A stereo frame is four bytes and takes eight clocks of the 974 a sample
  // period holds, because cd.vhd edge detects the strobe and so it has to fall
  // between bytes.
  reg [ 8:0] rd_word = 0;           // word within the chunk
  reg [31:0] frame;
  reg        head_pend = 1'b1;
  reg [ 2:0] fstep = 0;             // 0 idle, then 4 bytes over 8 clocks
  reg [31:0] pos;                   // byte offset of the next frame

  // Every audio byte offset is a multiple of four: track bases are sums of
  // whole sectors and 2048 and 2352 both divide by four. So the head skipped
  // off the first 512 byte block is a whole number of words and there is no
  // sub-word case to carry.
  wire [ 8:0] skip_words = {2'd0, start_off[8:2]};

  always @(posedge clk_sys) begin
    aud_req       <= 1'b0;
    aud_dm        <= 1'b0;
    rq            <= mem[{rd_chunk[2:0], rd_word}];
    rst_ack_sys_d <= rst_ack_sys;
    if (rst_ack_sys != rst_ack_sys_d) priming <= 1'b0;

    if (reset) begin
      rd_chunk <= 4'd0;
      rd_word  <= 9'd0;
      fstep    <= 3'd0;
      aud_busy <= 1'b0;
      ended    <= 1'b0;
      pos      <= 32'd0;
      priming  <= 1'b1;
    end else if (restart) begin
      rd_chunk <= 4'd0;
      rd_word  <= skip_words;
      fstep    <= 3'd0;
      aud_busy <= 1'b0;
      ended    <= 1'b0;
      pos       <= start_off;
      priming   <= 1'b1;
      head_pend <= 1'b1;
      aud_dm    <= 1'b1;            // resync cd.vhd's byte counter
    end else if (fstep != 3'd0) begin
      // Mid frame. Bytes go out low to high, which is the order cd.vhd packs
      // them and the order they sit in the file.
      fstep <= fstep + 3'd1;
      if (fstep[0]) begin           // odd steps strobe, even ones stay low
        aud_req  <= 1'b1;
        case (fstep[2:1])
          2'd0: aud_data <= frame[7:0];
          2'd1: aud_data <= frame[15:8];
          2'd2: aud_data <= frame[23:16];
          default: aud_data <= frame[31:24];
        endcase
      end
      if (fstep == 3'd7) begin
        fstep    <= 3'd0;
        aud_busy <= 1'b0;
      end
    end else if (ce_441 && play && !ended && !priming && have_data) begin
      frame    <= rq;
      // The first frame out of the ring after a restart, which is the audio
      // equivalent of the sector head: it says whether what the transport put
      // in the ring is the music that is in the file at that offset.
      if (head_pend) begin
        dbg_head  <= rq;
        head_pend <= 1'b0;
      end
      fstep    <= 3'd1;
      aud_busy <= 1'b1;
      pos      <= pos + 32'd4;
      if (pos + 32'd4 >= end_off) ended <= 1'b1;

      if (rd_word == CHUNK_WORDS - 9'd1) begin
        rd_word  <= 9'd0;
        rd_chunk <= rd_chunk + 4'd1;
      end else begin
        rd_word <= rd_word + 9'd1;
      end
    end
  end

endmodule

`default_nettype wire
