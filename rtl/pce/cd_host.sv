// SPDX-License-Identifier: GPL-3.0-or-later
//
// The CD drive, as the PC Engine's CD interface chip expects to find it.
//
// This is a reimplementation of `pcecdd.cpp` by srg320, the host-side drive
// model from TurboGrafx16_MiSTer, in RTL rather than C++. The opcode set, the
// two sense codes, the track clamping, the fixed responses and the decision to
// give seeks no latency at all are its design decisions, not this file's. No
// code was copied; the behaviour is its.
//
// Mazamars312's openfpga-pcengine-cd solves the same problem the other way, by
// putting a soft CPU in the fabric and running a firmware drive on it. See the
// README.
//
// `docs/CD-PLAN.md` P3. `cd.vhd` is only the interface chip: it speaks SCSI to
// a drive that, on MiSTer, is 900 lines of C++ running on a Linux host. The
// Pocket has no host, so the drive lives here. The specification this is built
// from is §5e of that document, extracted from `cd.vhd`, `SCSI.vhd` and
// MiSTer's `pcecdd.cpp`.
//
// ---- what the hardware demands, and why this is shaped the way it is ----
//
// **Phase order is not negotiable.** `SCSI.vhd` arbitrates in `SP_FREE` on a
// strict priority: select, then status, then queued data, then data-out. So
// pulsing `stat_get` while sector bytes are still in the FIFO makes the status
// phase jump the queue and the rest of the data arrives *after* the message.
// Every command therefore runs: decode, push all data, wait for `data_end`,
// then status. That ordering is the whole reason this is a sequencer and not
// a lookup table.
//
// **Underrun is the dangerous direction.** An empty SCSI FIFO at any byte
// boundary ends the data phase and pulses `data_end`, which the CPU reads as
// end of transfer. A short read looks exactly like a successful short read.
// So a sector is fetched whole before a single byte of it is pushed.
//
// **Every strobe to the core is a one-clock pulse.** `stat_get` and `dout_req`
// are level-sampled into sticky flags: hold either high and the core issues
// status phases forever.
//
// **`stat` and `msg` are sampled late.** The core reads `stat` about 1.05 ms
// after the pulse and `msg` about 2.2 ms after. Both are set before the pulse
// and held until the next command, which is why they are plain registers.
//
// ---- what this deliberately does not do yet ----
//
// CD-DA playback. The audio state, the play window and the modes are all
// tracked, and SAPSP/SAPEP/PAUSE answer correctly, but no audio is streamed:
// `audio_wr` is never asserted. That is P4, and it needs the 32KB ring that
// `READ6` and `PAUSE` flushing the core's CDDA FIFO makes necessary.
//
// No subcode, because `cd.vhd` has no port for it. No seek model, because the
// reference has a fast-seek path that sets every latency to zero and nothing
// on this machine can tell. Both are recorded in §5e.

`default_nettype none

module cd_host (
    input  wire        clk,              // clk_sys_42_95, the core's own clock
    input  wire        reset,
    input  wire        cd_en,

    // ---- to and from cd.vhd ----
    input  wire [95:0] comm,             // CDB, byte i at [8i+7:8i]
    input  wire        comm_send,        // one-clock pulse
    output reg  [ 7:0] stat,
    output reg  [ 7:0] msg,
    output reg         stat_get,         // one-clock pulse
    output reg         dout_req,         // one-clock pulse, unused in v1
    input  wire [79:0] dout,
    input  wire        dout_send,
    output reg  [ 7:0] data,
    output reg         data_wr,
    output reg         audio_wr,
    input  wire        data_end,         // one-clock pulse
    output reg         dm,
    input  wire        cd_reset,         // level
    output wire        region,

    // ---- the track table, from cd_toc ----
    output reg  [ 6:0] toc_track,        // 1-based
    input  wire [31:0] toc_lba,
    input  wire [31:0] toc_base,
    input  wire [11:0] toc_size,
    input  wire        toc_audio,
    input  wire [ 6:0] track_count,
    input  wire [31:0] toc_end,

    // ---- sector fetch, answered in the bridge clock domain ----
    output reg         fetch_req,        // level, held until fetch_done
    output reg  [31:0] fetch_offset,     // byte offset into the bin
    input  wire        fetch_done,
    output reg  [10:0] sec_addr,
    input  wire [ 7:0] sec_data,

    input  wire [ 3:0] fetch_err,      // last non-zero result from cd_fetch

    // ---- CD-DA, to cd_audio ----
    output reg         aud_play,      // level
    output reg         aud_restart,   // one clock
    output reg  [31:0] aud_start,     // byte offset of the first sample
    output reg  [31:0] aud_end,       // byte offset one past the last
    input  wire        aud_ended,
    input  wire [18:0] aud_sector,     // sectors played since the last restart
    input  wire [ 3:0] aud_level,
    input  wire [ 3:0] aud_err,
    input  wire [ 3:0] aud_wr,
    input  wire [ 3:0] aud_rd,
    input  wire [ 3:0] aud_room,
    input  wire [15:0] aud_ok,
    input  wire [15:0] aud_bad,
    input  wire [15:0] aud_secs,
    input  wire [15:0] aud_busy_ms,
    input  wire [31:0] aud_head,
    input  wire [ 7:0] aud_data,
    input  wire        aud_req,
    input  wire        aud_busy,
    input  wire        aud_dm,

    // Diagnostic block for the overlay: four rows of 26 characters, row 0 in
    // The SCSI data FIFO has no room. Until this existed the push side had no
    // flow control at all: a whole sector went in blind, and the data in phase
    // ended whenever the FIFO ran dry between one sector and the next.
    input  wire        fifo_full,

    // Straight from cd.vhd, same clock, so no crossing. Its port carries the
    // bit layout. All of it is on screen, on row 3.
    input  wire [47:0] dbg_cd,

    // the most significant 156 bits. Composed here so the whole of it lives in
    // one file. See the assembly at the foot.
    output wire [935:0] line
);

  // Region 0 is Japan, which is what Rondo wants.
  assign region = 1'b0;

  // ---- SCSI opcodes ----------------------------------------------------
  localparam [7:0] OP_TESTUNIT    = 8'h00;
  localparam [7:0] OP_REQSENSE    = 8'h03;
  localparam [7:0] OP_READ6       = 8'h08;
  localparam [7:0] OP_MODESELECT6 = 8'h15;
  localparam [7:0] OP_SAPSP       = 8'hD8;
  localparam [7:0] OP_SAPEP       = 8'hD9;
  localparam [7:0] OP_PAUSE       = 8'hDA;
  localparam [7:0] OP_READSUBQ    = 8'hDD;
  localparam [7:0] OP_GETDIRINFO  = 8'hDE;

  // Only two status values are ever sent and the message byte is always zero:
  // the reference never uses BUSY, CONDITION MET or INTERMEDIATE.
  localparam [7:0] ST_GOOD  = 8'h00;
  localparam [7:0] ST_CHECK = 8'h01;

  // Sense is set in exactly two places in the entire reference model.
  localparam [7:0] SK_NOT_READY = 8'h02, ASC_NO_DISC = 8'h0B;
  localparam [7:0] SK_ILLEGAL   = 8'h05, ASC_BAD_CMD = 8'h20;

  // Drive states, as pcecdd models them.
  localparam [2:0] DS_NODISC = 3'd0, DS_IDLE = 3'd1, DS_READ = 3'd2,
                   DS_PLAY   = 3'd3, DS_PAUSE = 3'd4;

  reg [2:0] dstate;

  // ---- persistent drive state ------------------------------------------
  reg [31:0] lba;                  // current head position
  reg [ 6:0] track;                // 1-based current track
  reg [ 8:0] cnt;                  // READ6 sectors remaining, 256 needs 9 bits
  reg [31:0] cdda_start, cdda_end;
  reg [ 7:0] cdda_mode;
  reg [ 7:0] sense_key, sense_asc;

  // ---- the CDB ---------------------------------------------------------
  // Bytes above the command's length are stale from whatever longer command
  // ran before: SCSI.vhd never clears the buffer and infers length from a
  // table indexed by the opcode's *high nibble*, not by SCSI group codes. Only
  // the bytes a command actually uses are read here, which sidesteps it.
  reg [95:0] cdb;
  wire [7:0] op = cdb[7:0];

  // Bit fields want plain wires: `cb(4'd9)[7:6]` is legal SystemVerilog and
  // Quartus's parser will not take a part-select applied to a function call.
  wire [7:0] cdb1 = cdb[15:8];
  wire [7:0] cdb2 = cdb[23:16];
  wire [7:0] cdb3 = cdb[31:24];
  wire [7:0] cdb4 = cdb[39:32];
  wire [7:0] cdb5 = cdb[47:40];
  wire [7:0] cdb9 = cdb[79:72];
  function automatic [7:0] cb(input [3:0] i);
    begin
      cb = cdb[{4'd0, i} * 8 +: 8];
    end
  endfunction

  // ---- response buffer -------------------------------------------------
  // 18 bytes is REQUESTSENSE, the longest non-sector reply.
  reg [7:0] rsp[0:17];
  reg [4:0] rsp_len;
  reg [4:0] rsp_pos;

  // ---- MSF conversion --------------------------------------------------
  // Sequential, by repeated subtraction. A 21-bit LBA needs at most about
  // 4,900 iterations, which is 114 us: the core itself takes 665 us to deliver
  // a six byte command, so this is never the slow part. A combinational
  // divider would be real logic on a path that runs once per command.
  reg [31:0] msf_acc;
  reg [ 7:0] msf_m, msf_s, msf_f;
  reg        msf_busy, msf_phase;
  reg        msf_pass;              // 0 relative, 1 absolute, for READSUBQ

  // Which head READSUBQ describes. While audio is playing or paused it is the
  // music; otherwise the last data read.
  wire        subq_playing = (dstate == DS_PLAY) || (dstate == DS_PAUSE);
  wire [31:0] subq_lba = subq_playing ? (aud_lba0 + {13'd0, aud_sector}) : lba;
  wire [31:0] subq_trk = subq_playing ? aud_trk_lba : trk_lba;

  function automatic [6:0] bcd_to_bin(input [7:0] v);
    begin
      bcd_to_bin = {3'd0, v[7:4]} * 7'd10 + {3'd0, v[3:0]};
    end
  endfunction

  function automatic [7:0] bcd(input [7:0] v);
    reg [7:0] t;
    begin
      t   = 8'd0;
      bcd = v;
      // v is always < 100 here, so a single ten-step chain is enough.
      if (bcd >= 8'd90) begin t = 8'h90; bcd = bcd - 8'd90; end
      else if (bcd >= 8'd80) begin t = 8'h80; bcd = bcd - 8'd80; end
      else if (bcd >= 8'd70) begin t = 8'h70; bcd = bcd - 8'd70; end
      else if (bcd >= 8'd60) begin t = 8'h60; bcd = bcd - 8'd60; end
      else if (bcd >= 8'd50) begin t = 8'h50; bcd = bcd - 8'd50; end
      else if (bcd >= 8'd40) begin t = 8'h40; bcd = bcd - 8'd40; end
      else if (bcd >= 8'd30) begin t = 8'h30; bcd = bcd - 8'd30; end
      else if (bcd >= 8'd20) begin t = 8'h20; bcd = bcd - 8'd20; end
      else if (bcd >= 8'd10) begin t = 8'h10; bcd = bcd - 8'd10; end
      bcd = t | bcd;
    end
  endfunction

  // ---- the sequencer ---------------------------------------------------
  localparam [3:0] S_IDLE     = 4'd0;
  localparam [3:0] S_DECODE   = 4'd1;
  localparam [3:0] S_MSF      = 4'd2;   // waiting on the converter
  localparam [3:0] S_BUILD    = 4'd3;   // assemble the reply
  localparam [3:0] S_SEEKTRK  = 4'd4;   // read the TOC entry for `track`
  localparam [3:0] S_FETCH    = 4'd5;   // pull a sector through the transport
  localparam [3:0] S_PUSH     = 4'd6;   // reply bytes into the SCSI FIFO
  localparam [3:0] S_PUSHSEC  = 4'd7;   // 2048 sector bytes
  localparam [3:0] S_WAITEND  = 4'd8;   // data phase drains
  localparam [3:0] S_STATUS   = 4'd9;   // one-clock stat_get
  localparam [3:0] S_SETTLE   = 4'd10;
  localparam [3:0] S_FINDTRK  = 4'd11;  // which track holds this LBA
  localparam [3:0] S_OFFSET   = 4'd12;  // the offset multiply, pipelined
  localparam [3:0] S_APOS     = 4'd13;  // an audio position becoming an LBA
  localparam [3:0] S_ATRK     = 4'd14;  // that position given as a track

  reg [ 3:0] state;
  reg [11:0] push_i;
  reg        push_ph;                 // strobe low half, so wr is 1 clk in 2
  reg [ 2:0] toc_wait;
  reg        pend_check;              // this command ends in CHECK CONDITION


  // Where in the bin a sector lives. Computed from the registered TOC entry,
  // never from a value arriving this cycle: P2 lost a build to exactly this
  // chain hanging off late data.
  reg [31:0] trk_lba, trk_base;
  reg [11:0] trk_size;
  reg        trk_audio;

  reg [ 6:0] scan_i;
  reg [ 1:0] off_step;
  reg [31:0] sec_index, sec_scaled;

  // The track walk and the offset multiply serve three callers now: a data
  // read, an audio start and an audio end. `scan_target` is what they agree
  // on and `off_mode` is where the answer goes.
  localparam [1:0] OFF_DATA = 2'd0, OFF_ASTART = 2'd1, OFF_AEND = 2'd2;
  reg [31:0] scan_target;
  reg [ 1:0] off_mode;

  // Where the audio head is, kept so READSUBQ can answer about the music
  // rather than about the last data sector read. Captured when a play start is
  // resolved, and added to cd_audio's sector count.
  reg [31:0] aud_lba0;              // LBA the play region starts at
  reg [31:0] aud_trk_lba;           // LBA its track starts at, for relative MSF
  reg [ 6:0] aud_track;

  reg [31:0] apos;                  // the LBA an audio command named
  reg [15:0] apos_ms;               // minutes and seconds, part way there
  reg [ 1:0] apos_step;
  // SAPSP and SAPEP each named a position and each carried a mode byte, and
  // one register holding whichever arrived last cannot say which mode belongs
  // to which command. Two of the three things still unknown about CD-DA are
  // read straight off these, so they are kept apart.
  reg [47:0] aud_cdb;               // SAPSP: bytes 1, 9, 2, 3, 4, 5
  reg [47:0] sep_cdb;               // SAPEP: the same six
  reg [15:0] subq_cnt;              // READSUBQ commands answered
  reg [15:0] ended_cnt;             // play regions that reached their end

  // The audio state outlives a data read and a bus reset both: neither one
  // stops the music, and before this the drive came back from either of them
  // claiming to be idle. `dstate` is what READSUBQ answers from, so that made
  // the drive lie about the music for the rest of the track.
  reg        aud_paused;            // seeked and holding, rather than idle

  // Counters and witnesses, for the diagnostic line only. Nothing reads them.
  reg [15:0] cmd_count, fetch_count;
  reg [ 7:0] last_op;
  reg [31:0] last_lba;                 // LBA of the last READ6
  reg [31:0] last_off;                 // byte offset the last fetch asked for
  reg [31:0] sec_head;                 // first four bytes handed to the core
  // A sum of every byte of the sector as it goes out, and the count byte the
  // READ6 asked for. The offset arithmetic is verified against the disc, so
  // what is left to doubt is the content: with the LBA on row 2 the same sum
  // can be computed from the bin on a PC and the two compared. If they agree
  // the sector left here byte perfect and the fault is past this module.
  reg [15:0] sec_sum;
  reg [ 7:0] rd_cnt0;

  // Sectors the game asked for, against `fetch_count` which is what it got.
  // The sector content is proven byte perfect and the game still lands in the
  // wrong place, so the remaining way to corrupt it is to deliver fewer
  // sectors than a READ6 asked for: the game fills part of a buffer, believes
  // it is loaded, and jumps into whatever the hole leaves behind. These two
  // numbers side by side answer that outright, and nothing so far has ever
  // compared them.
  reg [15:0] req_sec;
  // SCSI RST assertions. The CPU holds RST to abort, which abandons a command
  // mid transfer here, and that is one way the count could come up short.
  reg [ 7:0] rst_cnt;
  reg        cd_reset_d;
  reg [ 7:0] hist0, hist1, hist2, hist3, hist4, hist5;   // hist5 is newest

  wire [2:0] ds_resume = aud_play   ? DS_PLAY
                       : aud_paused ? DS_PAUSE : DS_IDLE;

  always @(posedge clk) begin
    // One-clock strobes, cleared every cycle and set where they are meant.
    stat_get    <= 1'b0;
    dout_req    <= 1'b0;
    data_wr     <= 1'b0;
    aud_restart <= 1'b0;

    // Counted on the edge: cd_reset is a level the CPU holds.
    cd_reset_d <= cd_reset;
    if (cd_reset && !cd_reset_d) rst_cnt <= rst_cnt + 8'd1;

    // cd.vhd edge detects both of these and shares one CD_DATA between them,
    // so they are strobes here for the same reason data_wr is.
    audio_wr    <= aud_req;
    dm          <= aud_dm;

    if (reset || !cd_en) begin
      state      <= S_IDLE;
      dstate     <= DS_NODISC;
      stat       <= ST_GOOD;
      msg        <= 8'h00;
      lba        <= 32'd0;
      track      <= 7'd1;
      cnt        <= 9'd0;
      sense_key  <= 8'h00;
      sense_asc  <= 8'h00;
      cdda_mode  <= 8'h00;
      fetch_req  <= 1'b0;
      msf_busy   <= 1'b0;
      pend_check <= 1'b0;
      aud_play    <= 1'b0;
      aud_paused  <= 1'b0;
      aud_lba0    <= 32'd0;
      aud_trk_lba <= 32'd0;
      aud_track   <= 7'd1;
      aud_start  <= 32'd0;
      aud_end    <= 32'd0;
      aud_cdb    <= 48'd0;
      sep_cdb    <= 48'd0;
      subq_cnt   <= 16'd0;
      ended_cnt  <= 16'd0;
      req_sec    <= 16'd0;
      rst_cnt    <= 8'd0;
      off_mode   <= OFF_DATA;
      cmd_count  <= 16'd0;
      fetch_count<= 16'd0;
      last_op    <= 8'hFF;
      last_lba   <= 32'd0;
      last_off   <= 32'd0;
      sec_head   <= 32'd0;
      {hist0, hist1, hist2, hist3, hist4, hist5} <= 48'hFFFFFFFFFFFF;
    end else if (cd_reset) begin
      // A level, not a pulse: the CPU holds SCSI RST while it aborts. The core
      // has already thrown away its own pending flags and flushed the FIFO, so
      // anything in flight here is gone too. Return to idle and wait to be
      // asked again; the core will not re-request.
      state     <= S_IDLE;
      fetch_req <= 1'b0;
      msf_busy  <= 1'b0;
      // CDDA does not run over the SCSI bus, so a bus reset does not stop it.
      if (dstate != DS_NODISC) dstate <= ds_resume;
    end else begin

      // A parsed cue is a disc in the drive, and nothing else was ever going
      // to say so: `dstate` came up as DS_NODISC and had no path out, so
      // TEST UNIT READY answered CHECK CONDITION / NOT READY forever and the
      // System Card sat on JUST A MOMENT waiting for a drive that kept
      // reporting an empty tray.
      //
      // Placed ahead of the case so a command arriving in the same cycle
      // still wins: last assignment inside one always block takes effect.
      if (dstate == DS_NODISC && track_count != 7'd0) dstate <= DS_IDLE;

      // The end of a play region. Nothing consumed this, so dstate stayed
      // DS_PLAY for ever once a track finished and a game polling READSUBQ for
      // track end would have waited for ever. Ahead of the case for the same
      // reason as the promotion above: a command arriving this cycle wins.
      //
      // Gated on `aud_ended` alone and not on `dstate == DS_PLAY`, because a
      // data read moves `dstate` and the music does not stop for it. With the
      // dstate test here, the first READ6 of a stage load left dstate at
      // DS_IDLE, and the end of that track was then never consumed at all:
      // `aud_play` stayed high for the rest of the run.
      //
      // `aud_ended` is a level held until the next restart, not a pulse, so
      // this re-fires until it takes. That is what settles the one cycle race
      // against a command in the case below: the case is later and wins, and
      // unless that command was the restart which clears `aud_ended`, this
      // fires again next cycle.
      //
      // It stops rather than repeating. The end-behaviour byte is recorded in
      // cdda_mode but what its values mean is not established, and a game that
      // wants a track again re-issues SAPSP.
      if (aud_ended) begin
        // Counted only on the edge, since the level holds: `aud_play` is high
        // for exactly the first cycle of it.
        if (aud_play) ended_cnt <= ended_cnt + 16'd1;
        aud_play   <= 1'b0;
        aud_paused <= 1'b0;
        if (dstate == DS_PLAY) dstate <= DS_IDLE;
      end

      // ---- the MSF converter, running whenever it has been started -------
      if (msf_busy) begin
        if (!msf_phase) begin
          // frames out of the LBA, seconds accumulating in msf_s
          if (msf_acc >= 32'd75) begin
            msf_acc <= msf_acc - 32'd75;
            msf_s   <= msf_s + 8'd1;
          end else begin
            msf_f     <= msf_acc[7:0];
            msf_acc   <= {24'd0, msf_s};
            msf_s     <= 8'd0;
            msf_phase <= 1'b1;
          end
        end else begin
          // minutes out of the seconds
          if (msf_acc >= 32'd60) begin
            msf_acc <= msf_acc - 32'd60;
            msf_m   <= msf_m + 8'd1;
          end else begin
            msf_s    <= msf_acc[7:0];
            msf_busy <= 1'b0;
          end
        end
      end

      case (state)

        // ------------------------------------------------------- idle ----
        S_IDLE: begin
          if (comm_send) begin
            cdb       <= comm;
            cmd_count <= cmd_count + 16'd1;
            last_op   <= comm[7:0];
            {hist0, hist1, hist2, hist3, hist4, hist5} <=
                {hist1, hist2, hist3, hist4, hist5, comm[7:0]};
            state     <= S_DECODE;
          end
        end

        // ----------------------------------------------------- decode ----
        S_DECODE: begin
          pend_check <= 1'b0;
          rsp_pos    <= 5'd0;
          case (op)

            OP_TESTUNIT: begin
              if (dstate == DS_NODISC) begin
                sense_key  <= SK_NOT_READY;
                sense_asc  <= ASC_NO_DISC;
                pend_check <= 1'b1;
              end
              rsp_len <= 5'd0;
              state   <= S_STATUS;
            end

            OP_REQSENSE: begin
              // Fixed format, 18 bytes. Reading sense clears it.
              rsp[0]  <= 8'h70;  rsp[1] <= 8'h00; rsp[2] <= 8'h00;
              rsp[3]  <= 8'h00;  rsp[4] <= sense_key;
              rsp[5]  <= 8'h00;  rsp[6] <= 8'h00; rsp[7] <= 8'h00;
              rsp[8]  <= 8'h00;  rsp[9] <= 8'h0A;
              rsp[10] <= 8'h00;  rsp[11] <= 8'h00; rsp[12] <= 8'h00;
              rsp[13] <= 8'h00;  rsp[14] <= sense_asc;
              rsp[15] <= 8'h00;  rsp[16] <= 8'h00; rsp[17] <= 8'h00;
              sense_key <= 8'h00;
              sense_asc <= 8'h00;
              rsp_len   <= 5'd18;
              state     <= S_PUSH;
            end

            OP_GETDIRINFO: begin
              case (cb(4'd1))
                8'h00: begin
                  // track range: first is the literal 1, last is BCD
                  rsp[0]  <= 8'h01;
                  rsp[1]  <= bcd({1'b0, track_count});
                  rsp[2]  <= 8'h00;
                  rsp[3]  <= 8'h00;
                  rsp_len <= 5'd4;
                  state   <= S_PUSH;
                end
                8'h01: begin
                  // leadout, absolute MSF with the 150 sector offset added
                  msf_acc   <= toc_end + 32'd150;
                  msf_m     <= 8'd0; msf_s <= 8'd0; msf_f <= 8'd0;
                  msf_phase <= 1'b0;
                  msf_busy  <= 1'b1;
                  rsp[3]    <= 8'h00;
                  rsp_len   <= 5'd4;
                  state     <= S_MSF;
                end
                default: begin
                  // track start. Clamp rather than index off the end: the
                  // reference does not, and reads tracks[-1] for track 0.
                  toc_track <= (cb(4'd2) == 8'h00) ? 7'd1
                             : (bcd_to_bin(cb(4'd2)) > track_count) ? track_count
                             : bcd_to_bin(cb(4'd2));
                  toc_wait  <= 3'd0;
                  state     <= S_SEEKTRK;
                end
              endcase
            end

            OP_READ6: begin
              // 21-bit big-endian LBA in bytes 1..3; byte 4 is the count with
              // 0 meaning 256.
              // Masked rather than bit-sliced: a part-select on a function
              // call is legal SystemVerilog and Quartus's parser rejects it.
              // The mask is what the reference applies anyway, dropping the
              // SCSI-1 LUN field in the top three bits.
              lba         <= {8'd0, cb(4'd1), cb(4'd2), cb(4'd3)} & 32'h001F_FFFF;
              scan_target <= {8'd0, cb(4'd1), cb(4'd2), cb(4'd3)} & 32'h001F_FFFF;
              off_mode    <= OFF_DATA;
              cnt       <= (cb(4'd4) == 8'd0) ? 9'd256 : {1'b0, cb(4'd4)};
              rd_cnt0   <= cb(4'd4);
              req_sec   <= req_sec + ((cb(4'd4) == 8'd0) ? 16'd256
                                                         : {8'd0, cb(4'd4)});
              dstate    <= DS_READ;
              scan_i    <= 7'd1;
              track     <= 7'd1;
              toc_track <= 7'd1;
              toc_wait  <= 3'd0;
              state     <= S_FINDTRK;
            end

            OP_MODESELECT6: begin
              // The reference discards the parameter list and changes nothing.
              // Answering GOOD without requesting it is the same outcome with
              // one less phase.
              rsp_len <= 5'd0;
              state   <= S_STATUS;
            end

            // Set audio playback start position. The address is given one of
            // three ways and the top two bits of byte 9 say which; byte 1 non
            // zero means play rather than seek and sit paused.
            //
            // This encoding is taken from the reference and has not been
            // confirmed against a disc. The six bytes are put on the overlay
            // for that reason: if a game addresses a track and gets silence,
            // the row says what it actually asked for.
            OP_SAPSP: begin
              aud_cdb   <= {cdb1, cdb9, cdb2, cdb3, cdb4, cdb5};
              cdda_mode <= cdb1;
              off_mode  <= OFF_ASTART;
              apos_step <= 2'd0;
              state     <= S_APOS;
            end

            // Set audio playback end position. Same decode, and it does not
            // disturb a stream already running: only where it stops.
            OP_SAPEP: begin
              sep_cdb   <= {cdb1, cdb9, cdb2, cdb3, cdb4, cdb5};
              cdda_mode <= cdb1;
              off_mode  <= OFF_AEND;
              apos_step <= 2'd0;
              state     <= S_APOS;
            end

            OP_PAUSE: begin
              // Unconditional GOOD, with no check that anything was playing.
              dstate     <= DS_PAUSE;
              aud_play   <= 1'b0;
              aud_paused <= 1'b1;
              rsp_len  <= 5'd0;
              state    <= S_STATUS;
            end

            OP_READSUBQ: begin
              // Counted because a game that is waiting on the drive polls
              // this and nothing else. Against the fetch count it separates
              // the two ways a load can stop: a poll that never gets the
              // answer it wants, or a transport that stopped delivering.
              subq_cnt <= subq_cnt + 16'd1;
              rsp[0] <= (dstate == DS_PAUSE) ? 8'h02
                      : (dstate == DS_PLAY)  ? 8'h00 : 8'h03;
              rsp[1] <= 8'h00;               // control/ADR, always zero
              rsp[2] <= bcd({1'b0, subq_playing ? aud_track : track});
              rsp[3] <= 8'h01;               // index, hardcoded
              // Relative first, then absolute: two passes of the converter.
              // Before this it ran once and put the absolute position in both
              // fields, and that position was `lba`, the data read head, which
              // during playback is wherever the last READ6 left it rather than
              // where the music is.
              msf_acc   <= subq_lba - subq_trk;
              msf_m     <= 8'd0; msf_s <= 8'd0; msf_f <= 8'd0;
              msf_phase <= 1'b0;
              msf_busy  <= 1'b1;
              msf_pass  <= 1'b0;
              rsp_len   <= 5'd10;
              state     <= S_MSF;
            end

            default: begin
              sense_key  <= SK_ILLEGAL;
              sense_asc  <= ASC_BAD_CMD;
              pend_check <= 1'b1;
              rsp_len    <= 5'd0;
              state      <= S_STATUS;
            end
          endcase
        end

        // -------------------------------------------- MSF then assemble ---
        S_MSF: if (!msf_busy) state <= S_BUILD;

        S_BUILD: begin
          if (op == OP_GETDIRINFO) begin
            rsp[0] <= bcd(msf_m);
            rsp[1] <= bcd(msf_s);
            rsp[2] <= bcd(msf_f);
            // rsp[3] is the control nibble for subcommand 2, already set
            state  <= S_PUSH;
          end else if (!msf_pass) begin
            // Relative is done. Run it again for the absolute position, which
            // carries the 150 sector lead-in offset that relative does not.
            rsp[4]    <= bcd(msf_m);
            rsp[5]    <= bcd(msf_s);
            rsp[6]    <= bcd(msf_f);
            msf_acc   <= subq_lba + 32'd150;
            msf_m     <= 8'd0; msf_s <= 8'd0; msf_f <= 8'd0;
            msf_phase <= 1'b0;
            msf_busy  <= 1'b1;
            msf_pass  <= 1'b1;
            state     <= S_MSF;
          end else begin
            rsp[7] <= bcd(msf_m);
            rsp[8] <= bcd(msf_s);
            rsp[9] <= bcd(msf_f);
            state  <= S_PUSH;
          end
        end

        // ------------------------------ an audio position becomes an LBA ---
        // Three cycles rather than one expression: the minutes-and-seconds
        // multiply feeding the seventy-five multiply feeding the subtract is
        // exactly the chain shape that cost P2 a build, and this clock has
        // 93 ps of slack to spare.
        S_APOS: begin
          case (cdb9[7:6])
            2'b00: begin
              // A plain LBA, big endian, in bytes 3 to 5.
              apos      <= {8'd0, cdb3, cdb4, cdb5};
              apos_step <= 2'd2;
            end
            2'b10: begin
              // A track number in BCD. Read its start out of the table rather
              // than compute anything.
              toc_track <= (bcd_to_bin(cdb2) == 7'd0) ? 7'd1
                         : (bcd_to_bin(cdb2) > track_count) ? track_count
                         : bcd_to_bin(cdb2);
              toc_wait  <= 3'd0;
              state     <= S_ATRK;
            end
            default: begin
              // MSF in BCD, bytes 2 to 4. The 150 sector offset comes back off
              // here because everything downstream works in LBA.
              case (apos_step)
                2'd0: begin
                  apos_ms   <= {9'd0, bcd_to_bin(cdb2)} * 16'd60
                             + {9'd0, bcd_to_bin(cdb3)};
                  apos_step <= 2'd1;
                end
                2'd1: begin
                  apos      <= {16'd0, apos_ms} * 32'd75
                             + {25'd0, bcd_to_bin(cdb4)} - 32'd150;
                  apos_step <= 2'd2;
                end
                default: ;
              endcase
            end
          endcase

          if (apos_step == 2'd2) begin
            scan_target <= apos;
            scan_i      <= 7'd1;
            toc_track   <= 7'd1;
            toc_wait    <= 3'd0;
            state       <= S_FINDTRK;
          end
        end

        S_ATRK: begin
          if (toc_wait != 3'd3) begin
            toc_wait <= toc_wait + 3'd1;
          end else begin
            apos        <= toc_lba;
            scan_target <= toc_lba;
            scan_i      <= 7'd1;
            toc_track   <= 7'd1;
            toc_wait    <= 3'd0;
            state       <= S_FINDTRK;
          end
        end

        // --------------------------------------------- TOC entry read -----
        // cd_toc registers its address and again its data, so the answer is
        // two clocks out. Three are taken, which costs nothing here.
        S_SEEKTRK: begin
          if (toc_wait != 3'd3) begin
            toc_wait <= toc_wait + 3'd1;
          end else begin
            trk_lba   <= toc_lba;
            trk_base  <= toc_base;
            trk_size  <= toc_size;
            trk_audio <= toc_audio;
            if (op == OP_GETDIRINFO) begin
              msf_acc   <= toc_lba + 32'd150;
              msf_m     <= 8'd0; msf_s <= 8'd0; msf_f <= 8'd0;
              msf_phase <= 1'b0;
              msf_busy  <= 1'b1;
              rsp[3]    <= toc_audio ? 8'h00 : 8'h04;   // control = type << 2
              rsp_len   <= 5'd4;
              state     <= S_MSF;
            end else begin
              state <= S_FETCH;
            end
          end
        end

        // ------------------------------------- which track holds the LBA --
        // A linear walk of the table, keeping the last track whose start is
        // at or below the target. 22 tracks is about 90 clocks, once per
        // command, against the 665 us the core spends delivering one.
        S_FINDTRK: begin
          if (toc_wait != 3'd3) begin
            toc_wait <= toc_wait + 3'd1;
          end else begin
            if (toc_lba <= scan_target) begin
              track     <= scan_i;
              trk_lba   <= toc_lba;
              trk_base  <= toc_base;
              trk_size  <= toc_size;
              trk_audio <= toc_audio;
            end
            if (scan_i == track_count) begin
              off_step <= 2'd0;
              state    <= S_OFFSET;
            end else begin
              scan_i    <= scan_i + 7'd1;
              toc_track <= scan_i + 7'd1;
              toc_wait  <= 3'd0;
            end
          end
        end

        // ------------------------------------------- the offset, staged ---
        // Three registered steps rather than one expression. Subtract, then
        // multiply, then add: P2 lost a build to a chain of exactly this shape
        // resolved in a single cycle, and this one is wider.
        S_OFFSET: begin
          case (off_step)
            2'd0: begin
              sec_index <= scan_target - trk_lba;
              off_step  <= 2'd1;
            end
            2'd1: begin
              sec_scaled <= sec_index * {20'd0, trk_size};
              off_step   <= 2'd2;
            end
            default: begin
              // A 2352 byte **data** sector carries 16 bytes of sync and
              // header before its 2048 bytes of user data. An audio sector of
              // the same size is 2352 bytes of samples and nothing else, so
              // the skip is conditioned on the track type and not on the size.
              // Getting that wrong shifts every audio track by four samples
              // and is inaudible, which is the kind of bug that survives.
              case (off_mode)
                OFF_ASTART: begin
                  aud_start   <= trk_base + sec_scaled;
                  aud_lba0    <= scan_target;
                  aud_trk_lba <= trk_lba;
                  aud_track   <= track;
                  // Nothing has said where to stop yet. SAPEP usually follows
                  // immediately; until it does, play to the end of the file.
                  aud_end     <= 32'hFFFF_FFFF;
                  aud_restart <= 1'b1;
                  aud_play    <= (cdda_mode != 8'h00);
                  aud_paused  <= (cdda_mode == 8'h00);
                  dstate      <= (cdda_mode == 8'h00) ? DS_PAUSE : DS_PLAY;
                  state       <= S_STATUS;
                end
                OFF_AEND: begin
                  aud_end  <= trk_base + sec_scaled;
                  aud_play   <= (cdda_mode != 8'h00);
                  aud_paused <= 1'b0;
                  dstate     <= (cdda_mode == 8'h00) ? DS_IDLE : DS_PLAY;
                  state    <= S_STATUS;
                end
                default: begin
                  fetch_offset <= trk_base + sec_scaled
                                + ((!trk_audio && trk_size == 12'd2352)
                                   ? 32'd16 : 32'd0);
                  state        <= S_FETCH;
                end
              endcase
              rsp_len <= 5'd0;
            end
          endcase
        end

        // ------------------------------------------------ sector fetch ----
        S_FETCH: begin
          if (!fetch_req && !fetch_done) begin
            fetch_req <= 1'b1;
            last_off  <= fetch_offset;
            // Per sector, not per command. Latching this at decode while
            // last_off moved every sector made a 32 sector READ6 report two
            // different points and look like an offset bug.
            last_lba  <= lba;
            sec_sum   <= 16'd0;
            // Park the read address on byte 0 here rather than on the way
            // out. cd_fetch registers its read, so sec_data trails sec_addr
            // by a clock; parking it now means byte 0 is already presented
            // when the sector lands. Setting it at the exit instead pushed a
            // stale byte first and shifted the whole sector down by one,
            // which loses byte 2047 and corrupts every sector silently.
            sec_addr  <= 11'd0;
            // `fetch_req` qualifies it. cd_fetch is a four phase handshake:
            // `done` is held until `req` drops and then clears through two
            // three deep synchronisers across the 74 and 43 MHz boundary,
            // about 140 ns. While the walk to the next sector went by way of
            // S_WAITEND that took milliseconds and the staleness never showed.
            // Chaining sectors to keep the data in phase open re-enters this
            // state about 93 ns later, and an unqualified `done` then completes
            // a fetch that was never issued: a stale buffer pushed as a sector
            // and `fetch_count` running ahead of what was asked for.
          end else if (fetch_req && fetch_done) begin
            fetch_req   <= 1'b0;
            fetch_count <= fetch_count + 16'd1;
            push_i      <= 12'd0;
            push_ph     <= 1'b0;
            state       <= S_PUSHSEC;
          end
        end

        // ------------------------------------------------- push a reply ---
        // Two clocks per byte: the core edge-detects the strobe, so it has to
        // return low between bytes.
        S_PUSH: begin
          if (aud_busy) begin
            // stand off; the audio frame owns the byte bus
          end else if (rsp_len == 5'd0) begin
            state <= S_STATUS;
          end else if (!push_ph) begin
            data    <= rsp[rsp_pos];
            data_wr <= 1'b1;
            push_ph <= 1'b1;
          end else begin
            push_ph <= 1'b0;
            if (rsp_pos + 5'd1 == rsp_len) state <= S_WAITEND;
            else rsp_pos <= rsp_pos + 5'd1;
          end
        end

        // -------------------------------------------- push a full sector --
        S_PUSHSEC: begin
          if (aud_busy || fifo_full) begin
            // Stand off: either the audio frame owns the byte bus, or the FIFO
            // is full and the next byte would be dropped. SCSI.vhd guards its
            // own write with the same flag, so without this the byte is lost
            // silently rather than delayed.
          end else if (!push_ph) begin
            data     <= sec_data;
            data_wr  <= 1'b1;
            push_ph  <= 1'b1;
            // The first four bytes of every sector, so the overlay can say
            // whether the transport delivered the sector that was asked for.
            if (push_i < 12'd4) sec_head <= {sec_head[23:0], sec_data};
            sec_sum <= sec_sum + {8'd0, sec_data};
            // Advance in the strobe phase, not the low one. sec_data trails
            // sec_addr by a clock and a byte takes two, so the address has to
            // move a full phase ahead of the byte that consumes it.
            sec_addr <= sec_addr + 11'd1;
          end else begin
            push_ph <= 1'b0;
            if (push_i == 12'd2047) begin
              // One data in phase per sector, deliberately. Chaining sectors
              // to keep a single phase open across a whole READ6, the way a
              // real drive answers one, stopped the core booting: `CD_DTR` in
              // cd.vhd is how the CPU learns a sector finished, and it drops
              // for exactly one clock at byte 2048 before the arming branch
              // above re-asserts it, because the phase conditions still hold.
              // Across a phase break it stays low for milliseconds; inside a
              // continuous phase the CPU cannot see it at all, and the System
              // Card re-read the same sectors for ever. See docs/CD-PLAN.md 5p.
              state <= S_WAITEND;
            end else push_i <= push_i + 12'd1;
          end
        end

        // ---------------------------------------------- data phase ends ---
        // Only the end of a command lands here now. The walk from one sector
        // to the next moved into S_PUSHSEC, so that a multi sector read never
        // lets the FIFO empty and never closes its data in phase early.
        S_WAITEND: begin
          if (data_end) begin
            if (op == OP_READ6) begin
              lba <= lba + 32'd1;
              if (cnt != 9'd1) begin
                cnt         <= cnt - 9'd1;
                off_step    <= 2'd0;
                off_mode    <= OFF_DATA;
                scan_target <= lba + 32'd1;
                state       <= S_OFFSET;
              end else begin
                cnt <= 9'd0;
                // Back to what the drive was doing, which is playing if the
                // music never stopped. Returning unconditionally to DS_IDLE
                // meant the first data read of a stage load knocked the drive
                // out of DS_PLAY behind the music's back. READSUBQ then
                // answered 03 stopped, and answered it about the data head
                // instead of the music, for the rest of the track.
                dstate <= ds_resume;
                state  <= S_STATUS;
              end
            end else begin
              state <= S_STATUS;
            end
          end
        end

        // ------------------------------------------------------ status ----
        S_STATUS: begin
          // stat and msg are sampled about 1.05 ms and 2.2 ms after this
          // pulse, so they are set here and held until the next command.
          stat     <= pend_check ? ST_CHECK : ST_GOOD;
          msg      <= 8'h00;
          stat_get <= 1'b1;
          state    <= S_SETTLE;
        end

        S_SETTLE: state <= S_IDLE;

        default: state <= S_IDLE;
      endcase

      // cd.vhd has one CD_DATA for sector bytes and audio bytes both, so they
      // cannot be presented in the same cycle. Audio wins, because its
      // deadline is a 44.1 kHz tick and the SCSI FIFO's is however long the
      // CPU takes to drain 2048 bytes. This assignment sits after the case so
      // it takes precedence; `aud_busy` holds the push states off for the
      // eight clocks a stereo frame occupies, which is 0.8% of the period.
      if (aud_req) data <= aud_data;
    end
  end

  // ---------------------------------------------------------- the block ----
  // Six rows, all visible at once. Paging them cost four screenshots to read
  // one state, and the two halves of a failure never appeared together.
  //
  //   T22 C001C OD9 S0 D3 F00C9    track count, commands answered, last
  //                                opcode, sequencer state, drive state,
  //                                sectors fetched
  //   H 08 08 08 08 D8 D9 E0 V00   the last six opcodes oldest first, the last
  //                                non-zero fetch result, and SCSI RST aborts
  //   L00000F5D A008BE830 Y0142    the LBA of the last READ6, the byte offset
  //                                it became, and READSUBQ commands answered
  //   M0000 N20 R0176 S057B3820    ADPCM_LEN, the count byte the READ6 asked
  //                                for, every sector every READ6 has asked
  //                                for, and where the audio was told to start
  //   Q 00 40 03 26 14 P1 Z0000    SAPSP in full: mode, address form, and the
  //                                three position bytes. Then playing, and
  //                                regions that reached their end
  //   R 01 40 04 50 48 X06293E50   SAPEP the same, then the end offset it
  //                                resolved to

  //
  // Rows 2 and 4 are the pair that says why a load stopped. `F` against `Y`
  // separates a transport that stopped delivering from a game polling the
  // drive for an answer it never gets: in a poll loop `Y` runs and `F` stands
  // still. `Z` against row 5 separates the two ways music can stop early, a
  // region that genuinely reached the end offset on screen, or something that
  // told it to stop; the mode bytes on row 4 say which command did.
  //
  // Row 3 answers whether a sector arrived intact. The offset arithmetic is
  // verified against the disc: LBA 0x0F5D resolves to 0x008BE830 and the bin
  // holds E5 E5 E5 E5 there, which is what the overlay showed. So position is
  // not in doubt and content is. `B` and `G` with the LBA on row 2 are enough
  // to recompute the same sum from the bin on a PC: if they agree the sector
  // left this module byte perfect and the corruption is past it, in the ADPCM
  // DMA or in what the CPU does with it.
  //
  // `N` is the count byte rather than the running `cnt`, because the question
  // is what was asked for, not what is left. A multi sector READ6 that crosses
  // a track boundary keeps the track it started in, which has never mattered
  // while Rondo's data was one track and would matter here.
  //
  // `D` is SCSI.vhd's own count of the bytes it handed the CPU in a data in
  // phase, reset when a command is selected. It has existed all along as
  // DBG_DATAIN_CNT and nothing was connected to it. Against `N` it is the only
  // thing that separates "the drive sent it" from "the CPU got it": a 32
  // sector read should hand over 0x10000, a 12 sector read 0x6000. Short means
  // the data phase ended early, which SCSI.vhd does the moment its FIFO runs
  // dry, and the game would fill part of a buffer and be told GOOD.
  //
  // `R` against `F` on row 0 is asked for against delivered, and both read
  // 0176 on hardware: the drive model delivers every sector it is asked for,
  // byte perfect, so nothing upstream of the FIFO is losing anything. `G` proved a sector arrives byte perfect, so
  // corrupt content is ruled out; delivering fewer sectors than were asked for
  // is not, and it produces exactly what is seen. The game fills part of a
  // buffer, is told GOOD, believes it is loaded, and jumps into the hole. If
  // R and F ever differ, that is the bug. `V` counts SCSI RST aborts, which is
  // one way a transfer could be cut short.
  //
  // ADPCM is not where the freeze is, which P13 established by putting the
  // whole engine on screen: both failure modes show ADPCM_CTRL 00 and only
  // ADPCM_END set, with no PLAY, no DMA_EN and no DMA_RUN. The stall theory
  // that build was made to catch does not happen, so the engine comes back off
  // the rows.
  //
  // What both failures have in common is this command pair. In one the game
  // issues SAPSP and SAPEP 19 times a second at the same region for ever; in
  // the other it issues SAPSP, gets no further, and sits at DS_PAUSE. And in
  // every frame ever captured `Z` is 0000: no play region has ever reached its
  // end.
  //
  // Two bytes of each command was not enough to say what was being asked for,
  // so both are now shown in full. `Q` and `R` carry the mode byte, the byte 9
  // that picks the address form, and the three position bytes, which for the
  // MSF form the game always uses are minutes, seconds and frames in BCD.
  // Against `X`, the offset SAPEP resolved to, that says whether the drive is
  // being asked for what it thinks it is.
  //
  // A frame of the game running and a frame of it hung differ in exactly one
  // bit of what is now `I`, ADPCM_HALF, with the SCSI phase, the command
  // count, the sector count and the checksums all identical. The bus sitting
  // in STATUS phase turned out to be the normal idle state, visible while the
  // game plays perfectly well, so it was never the hang it looked like.
  //
  //   bit 7 ADPCM_PLAY   6 ADPCM_DMA_EN   5 ADPCM_DMA_RUN
  //       4 DMA_WRITE_PEND
  //       3 ADPCM_READ_PEND  2 ADPCM_WRITE_PEND
  //       1 ADPCM_END        0 ADPCM_HALF
  //
  // That one bit is what row 3 is for now. `U` counts every byte the ADPCM DMA
  // lifted off the SCSI bus and `W` counts the subset it lifted with DMA_RUN
  // clear, meaning DMA_EN alone was holding it open. DMA_RUN clears itself
  // after 2048 bytes; DMA_EN does not, so a game that leaves it set has the
  // DMA feeding the next data in phase into ADPCM RAM whatever that phase was
  // for, which plays game data as samples and starves the CPU of the sector it
  // asked for. `W` moving while `O` reads 08 is the whole case. `K` is
  // ADPCM_CTRL, so what the game asked for sits beside what happened.
  //
  // Retired from these rows, each having answered its question: IRQ_N and the
  // seven bus lines, since no interrupt was ever armed and the bus was never
  // stuck; ADPCM_LEN; `N`, reads with a zero sector count; and `S`, the offset
  // SAPSP resolved to, which the PREGAP fix settled.

  // Font indices are ASCII - 32, matching cheat_font.
  localparam [5:0] SP = 6'd0, A_ = 6'd33, B_ = 6'd34, C_ = 6'd35, D_ = 6'd36,
                   E_ = 6'd37, F_ = 6'd38, H_ = 6'd40, L_ = 6'd44, N_ = 6'd46,
                   G_ = 6'd39, K_ = 6'd43, U_ = 6'd53,
                   O_ = 6'd47, P_ = 6'd48, Q_ = 6'd49, R_ = 6'd50, S_ = 6'd51,
                   T_ = 6'd52, W_ = 6'd55, X_ = 6'd56, Y_ = 6'd57, Z_ = 6'd58,
                   I_ = 6'd41, M_ = 6'd45, V_ = 6'd54;

  function automatic [5:0] hx(input [3:0] v);
    begin
      hx = (v < 4'd10) ? (6'h10 + {2'd0, v}) : (6'd33 + {2'd0, v} - 6'd10);
    end
  endfunction

  function automatic [11:0] hx2(input [7:0] v);
    begin
      hx2 = {hx(v[7:4]), hx(v[3:0])};
    end
  endfunction

  function automatic [23:0] hx4(input [15:0] v);
    begin
      hx4 = {hx(v[15:12]), hx(v[11:8]), hx(v[7:4]), hx(v[3:0])};
    end
  endfunction

  function automatic [47:0] hx8(input [31:0] v);
    begin
      hx8 = {hx(v[31:28]), hx(v[27:24]), hx(v[23:20]), hx(v[19:16]),
             hx(v[15:12]), hx(v[11:8]),  hx(v[7:4]),   hx(v[3:0])};
    end
  endfunction

  // Two decimal digits without a divider, the same comparison chain cd_toc
  // and cheat_osd use for the same reason.
  function automatic [3:0] tens_of(input [6:0] v);
    begin
      tens_of = (v >= 7'd90) ? 4'd9 : (v >= 7'd80) ? 4'd8 : (v >= 7'd70) ? 4'd7 :
                (v >= 7'd60) ? 4'd6 : (v >= 7'd50) ? 4'd5 : (v >= 7'd40) ? 4'd4 :
                (v >= 7'd30) ? 4'd3 : (v >= 7'd20) ? 4'd2 : (v >= 7'd10) ? 4'd1 :
                4'd0;
    end
  endfunction

  wire [3:0] tk_tens = tens_of(track_count);
  wire [6:0] tk_rem  = track_count - ({3'd0, tk_tens} * 7'd10);

  wire [155:0] row0 = {
      T_, hx(tk_tens), hx(tk_rem[3:0]), SP,
      C_, hx4(cmd_count), SP,
      O_, hx2(last_op), SP,
      S_, hx(state), SP,
      D_, hx({1'b0, dstate}), SP,
      F_, hx4(fetch_count), SP
  };

  wire [155:0] row1 = {
      H_, SP, hx2(hist0), SP, hx2(hist1), SP, hx2(hist2), SP,
              hx2(hist3), SP, hx2(hist4), SP, hx2(hist5), SP,
      E_, hx(fetch_err), SP,
      V_, hx2(rst_cnt)
  };

  wire [155:0] row2 = {
      L_, hx8(last_lba), SP,
      A_, hx8(last_off), SP,
      Y_, hx4(subq_cnt), SP
  };

  // U counts every byte the ADPCM DMA lifted off the SCSI bus. W counts the
  // subset it lifted with only DMA_EN set, which is the case nobody asked for:
  // DMA_RUN clears itself after a sector, DMA_EN does not, so a game that
  // leaves it set feeds the next data in phase into ADPCM RAM whatever that
  // phase was for. W moving while O reads 08 is the answer to both the random
  // samples and the freeze. K is ADPCM_CTRL, I the ADPCM flags.
  wire [155:0] row3 = {
      U_, hx4(dbg_cd[47:32]), SP,
      W_, hx4(dbg_cd[31:16]), SP,
      K_, hx2(dbg_cd[15:8]),  SP,
      I_, hx2(dbg_cd[7:0]),   SP,
      R_, hx4(req_sec), SP
  };

  // The two audio commands as they arrived, apart: Q is SAPSP and R is SAPEP,
  // each showing its byte 1 and its byte 9. Byte 9's top two bits pick the
  // address form; byte 1 is the mode, and what its values mean is the one
  // thing about CD-DA still taken on trust. Z counts regions that reached
  // their end, which is the other half of the same question: a track that
  // stops when it should not either hit its end or was told to stop, and
  // nothing else can tell those apart.
  wire [155:0] row4 = {
      Q_, SP, hx2(aud_cdb[47:40]), SP, hx2(aud_cdb[39:32]), SP,
                hx2(aud_cdb[31:24]), SP, hx2(aud_cdb[23:16]), SP,
                hx2(aud_cdb[15:8]),  SP,
      P_, hx({3'd0, aud_play}), SP,
      Z_, hx4(ended_cnt), SP
  };

  wire [155:0] row5 = {
      R_, SP, hx2(sep_cdb[47:40]), SP, hx2(sep_cdb[39:32]), SP,
                hx2(sep_cdb[31:24]), SP, hx2(sep_cdb[23:16]), SP,
                hx2(sep_cdb[15:8]),  SP,
      X_, hx8(aud_end)
  };

  // The counters run in this clock and the overlay reads them in another, so
  // the assembled block is registered on a slow divider rather than crossed
  // live. Every 4096 clocks is 95 us, which is thousands of overlay clocks of
  // settling either side, and registering the whole block rather than each
  // field means the four rows are always the same instant.
  reg [11:0]  snap_div = 0;
  reg [935:0] line_r = 0;

  always @(posedge clk) begin
    snap_div <= snap_div + 12'd1;
    if (snap_div == 12'd0) line_r <= {row0, row1, row2, row3, row4, row5};
  end

  assign line = line_r;

endmodule

`default_nettype wire
