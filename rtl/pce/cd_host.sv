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
    output wire        audio_wr,
    input  wire        data_end,         // one-clock pulse
    output wire        dm,
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

    // Diagnostic block for the overlay: four rows of 26 characters, row 0 in
    // the most significant 156 bits. Composed here so the whole of it lives in
    // one file. See the assembly at the foot.
    output wire [623:0] line
);

  // v1 leaves these constant. Region 0 is Japan, which is what Rondo wants;
  // dm resynchronises the CDDA byte packer and only matters once audio flows.
  assign audio_wr = 1'b0;
  assign dm       = 1'b0;
  assign region   = 1'b0;

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

  // Counters and witnesses, for the diagnostic line only. Nothing reads them.
  reg [15:0] cmd_count, fetch_count;
  reg [ 7:0] last_op;
  reg [31:0] last_lba;                 // LBA of the last READ6
  reg [31:0] last_off;                 // byte offset the last fetch asked for
  reg [31:0] sec_head;                 // first four bytes handed to the core
  reg [ 7:0] hist0, hist1, hist2, hist3, hist4, hist5;   // hist5 is newest

  always @(posedge clk) begin
    // One-clock strobes, cleared every cycle and set where they are meant.
    stat_get <= 1'b0;
    dout_req <= 1'b0;
    data_wr  <= 1'b0;

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
      if (dstate != DS_NODISC) dstate <= DS_IDLE;
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
              lba       <= {8'd0, cb(4'd1), cb(4'd2), cb(4'd3)} & 32'h001F_FFFF;
              last_lba  <= {8'd0, cb(4'd1), cb(4'd2), cb(4'd3)} & 32'h001F_FFFF;
              cnt       <= (cb(4'd4) == 8'd0) ? 9'd256 : {1'b0, cb(4'd4)};
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

            OP_SAPSP: begin
              cdda_mode  <= cb(4'd1);
              cdda_start <= lba;
              cdda_end   <= toc_end;
              dstate     <= (cb(4'd1) == 8'h00) ? DS_PAUSE : DS_PLAY;
              rsp_len    <= 5'd0;
              state      <= S_STATUS;
            end

            OP_SAPEP: begin
              cdda_mode <= cb(4'd1);
              dstate    <= (cb(4'd1) == 8'h00) ? DS_IDLE : DS_PLAY;
              rsp_len   <= 5'd0;
              state     <= S_STATUS;
            end

            OP_PAUSE: begin
              // Unconditional GOOD, with no check that anything was playing.
              dstate  <= DS_PAUSE;
              rsp_len <= 5'd0;
              state   <= S_STATUS;
            end

            OP_READSUBQ: begin
              rsp[0] <= (dstate == DS_PAUSE) ? 8'h02
                      : (dstate == DS_PLAY)  ? 8'h00 : 8'h03;
              rsp[1] <= 8'h00;               // control/ADR, always zero
              rsp[2] <= bcd({1'b0, track});
              rsp[3] <= 8'h01;               // index, hardcoded
              // Relative and absolute MSF want two conversions; v1 reports the
              // absolute position twice rather than running the converter
              // twice, which no known title checks.
              msf_acc   <= lba + 32'd150;
              msf_m     <= 8'd0; msf_s <= 8'd0; msf_f <= 8'd0;
              msf_phase <= 1'b0;
              msf_busy  <= 1'b1;
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
          end else begin
            rsp[4] <= bcd(msf_m);  rsp[5] <= bcd(msf_s);  rsp[6] <= bcd(msf_f);
            rsp[7] <= bcd(msf_m);  rsp[8] <= bcd(msf_s);  rsp[9] <= bcd(msf_f);
          end
          state <= S_PUSH;
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
            if (toc_lba <= lba) begin
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
              sec_index <= lba - trk_lba;
              off_step  <= 2'd1;
            end
            2'd1: begin
              sec_scaled <= sec_index * {20'd0, trk_size};
              off_step   <= 2'd2;
            end
            default: begin
              // A 2352 byte sector carries 16 bytes of sync and header before
              // its 2048 bytes of user data. Skipping it here keeps the
              // fetcher a plain byte-range reader.
              fetch_offset <= trk_base + sec_scaled
                            + ((trk_size == 12'd2352) ? 32'd16 : 32'd0);
              state        <= S_FETCH;
            end
          endcase
        end

        // ------------------------------------------------ sector fetch ----
        S_FETCH: begin
          if (!fetch_req && !fetch_done) begin
            fetch_req <= 1'b1;
            last_off  <= fetch_offset;
            // Park the read address on byte 0 here rather than on the way
            // out. cd_fetch registers its read, so sec_data trails sec_addr
            // by a clock; parking it now means byte 0 is already presented
            // when the sector lands. Setting it at the exit instead pushed a
            // stale byte first and shifted the whole sector down by one,
            // which loses byte 2047 and corrupts every sector silently.
            sec_addr  <= 11'd0;
          end else if (fetch_done) begin
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
          if (rsp_len == 5'd0) begin
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
          if (!push_ph) begin
            data     <= sec_data;
            data_wr  <= 1'b1;
            push_ph  <= 1'b1;
            // The first four bytes of every sector, so the overlay can say
            // whether the transport delivered the sector that was asked for.
            if (push_i < 12'd4) sec_head <= {sec_head[23:0], sec_data};
            // Advance in the strobe phase, not the low one. sec_data trails
            // sec_addr by a clock and a byte takes two, so the address has to
            // move a full phase ahead of the byte that consumes it.
            sec_addr <= sec_addr + 11'd1;
          end else begin
            push_ph <= 1'b0;
            if (push_i == 12'd2047) state <= S_WAITEND;
            else push_i <= push_i + 12'd1;
          end
        end

        // ---------------------------------------------- data phase ends ---
        S_WAITEND: begin
          if (data_end) begin
            if (op == OP_READ6) begin
              lba <= lba + 32'd1;
              if (cnt == 9'd1) begin
                cnt    <= 9'd0;
                dstate <= DS_IDLE;
                state  <= S_STATUS;
              end else begin
                cnt      <= cnt - 9'd1;
                off_step <= 2'd0;
                state    <= S_OFFSET;
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
    end
  end

  // ---------------------------------------------------------- the block ----
  // Four rows, all visible at once. Paging them cost four screenshots to read
  // one state, and the two halves of a failure never appeared together.
  //
  //   T22 C0012 O08 S5 D2 F0004    tracks, commands, opcode, sequencer state,
  //                                drive state, sectors fetched
  //   H 00 DE DE DE DE 08 E0       the last six opcodes oldest first, then the
  //                                last non-zero fetch result
  //   L00000E51 A00838830          the LBA asked for and the byte offset it
  //                                was turned into
  //   B00000000                    the first four bytes handed to the core
  //
  // The last two are the ones that matter: rows 2 and 3 together say what was
  // asked for, where it landed, and whether what came back is what is there.
  // A00838830 with B00000000 is a read that failed silently; the E field on
  // row 1 says so outright.

  // Font indices are ASCII - 32, matching cheat_font.
  localparam [5:0] SP = 6'd0, A_ = 6'd33, B_ = 6'd34, C_ = 6'd35, D_ = 6'd36,
                   E_ = 6'd37, F_ = 6'd38, H_ = 6'd40, L_ = 6'd44, O_ = 6'd47,
                   S_ = 6'd51, T_ = 6'd52;

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
      E_, hx(fetch_err),
      SP, SP, SP, SP
  };

  wire [155:0] row2 = {
      L_, hx8(last_lba), SP,
      A_, hx8(last_off),
      SP, SP, SP, SP, SP, SP, SP
  };

  wire [155:0] row3 = {
      B_, hx8(sec_head),
      SP, SP, SP, SP, SP, SP, SP, SP, SP, SP, SP, SP, SP, SP, SP, SP, SP
  };

  // The counters run in this clock and the overlay reads them in another, so
  // the assembled block is registered on a slow divider rather than crossed
  // live. Every 4096 clocks is 95 us, which is thousands of overlay clocks of
  // settling either side, and registering the whole block rather than each
  // field means the four rows are always the same instant.
  reg [11:0]  snap_div = 0;
  reg [623:0] line_r = 0;

  always @(posedge clk) begin
    snap_div <= snap_div + 12'd1;
    if (snap_div == 12'd0) line_r <= {row0, row1, row2, row3};
  end

  assign line = line_r;

endmodule

`default_nettype wire
