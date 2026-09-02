// SPDX-License-Identifier: GPL-3.0-or-later
//
// Pulls one 2048 byte sector off the SD card and hands it to the drive model.
//
// `docs/CD-PLAN.md` P3. This is the join between the two halves of the CD
// work: the transport proved in P0 and P1 lives on `clk_74a` with the bridge,
// and `cd_host` lives on `clk_sys_42_95` with the rest of the core, because
// that is the clock `cd.vhd` runs on.
//
// A whole sector is buffered before the drive model is told it has one. That
// is not caution, it is required: an empty SCSI FIFO at any byte boundary ends
// the data phase and the CPU reads it as end of transfer, so a sector that
// arrives in pieces looks like a successful short read. See §5e.
//
// ---- the crossing ----
//
// A four-phase handshake. `req` is a level raised by `cd_host` and held until
// `done` comes back; `offset` is set before `req` rises and does not change
// while it is high, so it crosses without synchronisers by construction rather
// than by luck. Only the two handshake bits are synchronised, which is the
// only part that needs to be.
//
// 8KB was measured as the fastest request size in P0, 1104 KB/s against 453 at
// 512 bytes, so a future version should read four sectors at once and serve
// three of them from the buffer. v1 reads one, because the drive model asks
// for one and correctness comes before the 2.4x.

`default_nettype none

module cd_fetch #(
    // The deferload slot the bin is opened into by dataslot_path.
    parameter [15:0] SLOT_ID = 16'd101,

    // Its own bridge window: 0x60 is the throughput probe's and 0x61 is the
    // path prober's struct RAM.
    parameter [31:0] WINDOW = 32'h6200_0000,

    parameter [31:0] SECTOR = 32'd2048
) (
    input  wire        clk_74a,
    input  wire        clk_sys,
    input  wire        reset,

    // ---- to and from cd_host, in clk_sys ----
    // `ready` means the bin has been opened into SLOT_ID. Without it the first
    // read can beat dataslot_path's open and come back empty, which reads as a
    // sector of zeroes rather than as a failure.
    input  wire        ready,
    input  wire        req,
    input  wire [31:0] offset,
    output wire        done,
    input  wire [10:0] sec_addr,
    output wire [ 7:0] sec_data,

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

    output reg  [ 3:0] err
);

  assign cmd = 16'h0180;   // data slot read

  // ---- alignment ---------------------------------------------------------
  // Nothing in the APF documentation this tree carries says whether a data
  // slot read may start at an arbitrary byte, and every offset P0 and P1 ever
  // tested was zero. Rondo cannot avoid the question: its track 1 is AUDIO, so
  // the 2352 byte sectors ahead of the data track leave every data sector at
  // file offset 3665*2352 + n*2048, which is 48 past a 512 byte boundary and
  // stays there for the whole track.
  //
  // So ask only for whole 512 byte blocks and throw away the head. That is
  // correct whether or not the transport cared, and it costs one extra block
  // per sector plus two more M10K for the wider buffer.
  reg  [ 8:0] skew;                       // offset within the first block
  wire [31:0] aligned = offset & ~32'd511;
  wire [31:0] length  = (offset[8:0] == 9'd0) ? SECTOR : (SECTOR + 32'd512);

  // ---- the sector buffer ------------------------------------------------
  // 1024 words of 32 bits, one writer on the bridge clock and one reader on
  // the core clock, which is the shape that infers a dual-clock M10K. Four
  // blocks, up from two: 2048 bytes of sector plus up to 511 of discarded head
  // needs 2560, and the next power of two is 4096.
  // Bytes are big-endian in a word because core_top ties bridge_endian_little
  // low, so byte 0 of a word is bits [31:24].
  reg [31:0] mem[0:1023];
  reg [31:0] rq;

  wire       win_hit = bridge_wr && (bridge_addr[31:24] == WINDOW[31:24]);

  always @(posedge clk_74a) begin
    if (win_hit) mem[bridge_addr[11:2]] <= bridge_wr_data;
  end

  // The drive asks for byte 0..2047 of its sector; that is `skew` bytes into
  // what was actually read. 511 + 2047 needs twelve bits.
  wire [11:0] pbyte = {3'd0, skew} + {1'b0, sec_addr};

  reg [1:0] rd_lane;
  always @(posedge clk_sys) begin
    rq      <= mem[pbyte[11:2]];
    rd_lane <= pbyte[1:0];
  end

  assign sec_data = (rd_lane == 2'd0) ? rq[31:24]
                  : (rd_lane == 2'd1) ? rq[23:16]
                  : (rd_lane == 2'd2) ? rq[15:8]
                  : rq[7:0];

  // ---- the handshake ----------------------------------------------------
  // `skew` is captured in the core clock, where it is used. `offset` is a
  // cd_host register in that same clock, set before req rises and held until
  // done, so this samples a settled value and needs no crossing of its own.
  always @(posedge clk_sys) begin
    if (req && !done) skew <= offset[8:0];
  end

  wire req_74, ready_74;
  synch_3 s_req (req, req_74, clk_74a);
  synch_3 s_rdy (ready, ready_74, clk_74a);

  reg done_74;
  wire done_sys;
  synch_3 s_done (done_74, done_sys, clk_sys);
  assign done = done_sys;

  localparam [1:0] F_IDLE = 2'd0, F_ISSUE = 2'd1, F_WAIT = 2'd2, F_HOLD = 2'd3;
  reg [1:0] fstate;

  always @(posedge clk_74a) begin
    if (reset) begin
      fstate  <= F_IDLE;
      cmd_req <= 1'b0;
      done_74 <= 1'b0;
      err     <= 4'd0;
    end else begin
      case (fstate)
        F_IDLE: begin
          done_74 <= 1'b0;
          if (req_74 && ready_74) begin
            cmd_p0 <= {16'd0, SLOT_ID};
            cmd_p1 <= aligned;     // stable for the whole handshake
            cmd_p2 <= WINDOW;
            cmd_p3 <= length;
            fstate <= F_ISSUE;
          end
        end

        F_ISSUE: begin
          cmd_req <= 1'b1;
          fstate  <= F_WAIT;
        end

        F_WAIT: begin
          if (cmd_ack) cmd_req <= 1'b0;
          if (cmd_done) begin
            if (cmd_result != 16'd0) err <= cmd_result[3:0];
            done_74 <= 1'b1;
            fstate  <= F_HOLD;
          end
        end

        // Hold done until the requester has seen it and dropped req. Without
        // this the next fetch could see a stale done and push an unwritten
        // buffer, which is the P1 false-pass shape in a different place.
        F_HOLD: if (!req_74) fstate <= F_IDLE;

        default: fstate <= F_IDLE;
      endcase
    end
  end

endmodule

`default_nettype wire
