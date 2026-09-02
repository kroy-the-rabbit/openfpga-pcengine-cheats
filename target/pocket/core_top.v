//
// User core top-level
//
// Instantiated by the real top-level: apf_top
//

`default_nettype none

module core_top (

    //
    // physical connections
    //

    ///////////////////////////////////////////////////
    // clock inputs 74.25mhz. not phase aligned, so treat these domains as asynchronous

    input wire clk_74a,  // mainclk1
    input wire clk_74b,  // mainclk1 

    ///////////////////////////////////////////////////
    // cartridge interface
    // switches between 3.3v and 5v mechanically
    // output enable for multibit translators controlled by pic32

    // GBA AD[15:8]
    inout  wire [7:0] cart_tran_bank2,
    output wire       cart_tran_bank2_dir,

    // GBA AD[7:0]
    inout  wire [7:0] cart_tran_bank3,
    output wire       cart_tran_bank3_dir,

    // GBA A[23:16]
    inout  wire [7:0] cart_tran_bank1,
    output wire       cart_tran_bank1_dir,

    // GBA [7] PHI#
    // GBA [6] WR#
    // GBA [5] RD#
    // GBA [4] CS1#/CS#
    //     [3:0] unwired
    inout  wire [7:4] cart_tran_bank0,
    output wire       cart_tran_bank0_dir,

    // GBA CS2#/RES#
    inout  wire cart_tran_pin30,
    output wire cart_tran_pin30_dir,
    // when GBC cart is inserted, this signal when low or weak will pull GBC /RES low with a special circuit
    // the goal is that when unconfigured, the FPGA weak pullups won't interfere.
    // thus, if GBC cart is inserted, FPGA must drive this high in order to let the level translators
    // and general IO drive this pin.
    output wire cart_pin30_pwroff_reset,

    // GBA IRQ/DRQ
    inout  wire cart_tran_pin31,
    output wire cart_tran_pin31_dir,

    // infrared
    input  wire port_ir_rx,
    output wire port_ir_tx,
    output wire port_ir_rx_disable,

    // GBA link port
    inout  wire port_tran_si,
    output wire port_tran_si_dir,
    inout  wire port_tran_so,
    output wire port_tran_so_dir,
    inout  wire port_tran_sck,
    output wire port_tran_sck_dir,
    inout  wire port_tran_sd,
    output wire port_tran_sd_dir,

    ///////////////////////////////////////////////////
    // cellular psram 0 and 1, two chips (64mbit x2 dual die per chip)

    output wire [21:16] cram0_a,
    inout  wire [ 15:0] cram0_dq,
    input  wire         cram0_wait,
    output wire         cram0_clk,
    output wire         cram0_adv_n,
    output wire         cram0_cre,
    output wire         cram0_ce0_n,
    output wire         cram0_ce1_n,
    output wire         cram0_oe_n,
    output wire         cram0_we_n,
    output wire         cram0_ub_n,
    output wire         cram0_lb_n,

    output wire [21:16] cram1_a,
    inout  wire [ 15:0] cram1_dq,
    input  wire         cram1_wait,
    output wire         cram1_clk,
    output wire         cram1_adv_n,
    output wire         cram1_cre,
    output wire         cram1_ce0_n,
    output wire         cram1_ce1_n,
    output wire         cram1_oe_n,
    output wire         cram1_we_n,
    output wire         cram1_ub_n,
    output wire         cram1_lb_n,

    ///////////////////////////////////////////////////
    // sdram, 512mbit 16bit

    output wire [12:0] dram_a,
    output wire [ 1:0] dram_ba,
    inout  wire [15:0] dram_dq,
    output wire [ 1:0] dram_dqm,
    output wire        dram_clk,
    output wire        dram_cke,
    output wire        dram_ras_n,
    output wire        dram_cas_n,
    output wire        dram_we_n,

    ///////////////////////////////////////////////////
    // sram, 1mbit 16bit

    output wire [16:0] sram_a,
    inout  wire [15:0] sram_dq,
    output wire        sram_oe_n,
    output wire        sram_we_n,
    output wire        sram_ub_n,
    output wire        sram_lb_n,

    ///////////////////////////////////////////////////
    // vblank driven by dock for sync in a certain mode

    input wire vblank,

    ///////////////////////////////////////////////////
    // i/o to 6515D breakout usb uart

    output wire dbg_tx,
    input  wire dbg_rx,

    ///////////////////////////////////////////////////
    // i/o pads near jtag connector user can solder to

    output wire user1,
    input  wire user2,

    ///////////////////////////////////////////////////
    // RFU internal i2c bus 

    inout  wire aux_sda,
    output wire aux_scl,

    ///////////////////////////////////////////////////
    // RFU, do not use
    output wire vpll_feed,


    //
    // logical connections
    //

    ///////////////////////////////////////////////////
    // video, audio output to scaler
    output wire [23:0] video_rgb,
    output wire        video_rgb_clock,
    output wire        video_rgb_clock_90,
    output wire        video_de,
    output wire        video_skip,
    output wire        video_vs,
    output wire        video_hs,

    output wire audio_mclk,
    input  wire audio_adc,
    output wire audio_dac,
    output wire audio_lrck,

    ///////////////////////////////////////////////////
    // bridge bus connection
    // synchronous to clk_74a
    output wire        bridge_endian_little,
    input  wire [31:0] bridge_addr,
    input  wire        bridge_rd,
    output reg  [31:0] bridge_rd_data,
    input  wire        bridge_wr,
    input  wire [31:0] bridge_wr_data,

    ///////////////////////////////////////////////////
    // controller data
    // 
    // key bitmap:
    //   [0]    dpad_up
    //   [1]    dpad_down
    //   [2]    dpad_left
    //   [3]    dpad_right
    //   [4]    face_a
    //   [5]    face_b
    //   [6]    face_x
    //   [7]    face_y
    //   [8]    trig_l1
    //   [9]    trig_r1
    //   [10]   trig_l2
    //   [11]   trig_r2
    //   [12]   trig_l3
    //   [13]   trig_r3
    //   [14]   face_select
    //   [15]   face_start
    // joy values - unsigned
    //   [ 7: 0] lstick_x
    //   [15: 8] lstick_y
    //   [23:16] rstick_x
    //   [31:24] rstick_y
    // trigger values - unsigned
    //   [ 7: 0] ltrig
    //   [15: 8] rtrig
    //
    input wire [15:0] cont1_key,
    input wire [15:0] cont2_key,
    input wire [15:0] cont3_key,
    input wire [15:0] cont4_key,
    input wire [31:0] cont1_joy,
    input wire [31:0] cont2_joy,
    input wire [31:0] cont3_joy,
    input wire [31:0] cont4_joy,
    input wire [15:0] cont1_trig,
    input wire [15:0] cont2_trig,
    input wire [15:0] cont3_trig,
    input wire [15:0] cont4_trig

);

  // not using the IR port, so turn off both the LED, and
  // disable the receive circuit to save power
  assign port_ir_tx              = 0;
  assign port_ir_rx_disable      = 1;

  // bridge endianness
  assign bridge_endian_little    = 0;

  // cart is unused, so set all level translators accordingly
  // directions are 0:IN, 1:OUT
  assign cart_tran_bank3         = 8'hzz;
  assign cart_tran_bank3_dir     = 1'b0;
  assign cart_tran_bank2         = 8'hzz;
  assign cart_tran_bank2_dir     = 1'b0;
  assign cart_tran_bank1         = 8'hzz;
  assign cart_tran_bank1_dir     = 1'b0;
  assign cart_tran_bank0         = 4'hf;
  assign cart_tran_bank0_dir     = 1'b1;
  assign cart_tran_pin30         = 1'b0;  // reset or cs2, we let the hw control it by itself
  assign cart_tran_pin30_dir     = 1'bz;
  assign cart_pin30_pwroff_reset = 1'b0;  // hardware can control this
  assign cart_tran_pin31         = 1'bz;  // input
  assign cart_tran_pin31_dir     = 1'b0;  // input

  // link port is input only
  assign port_tran_so            = 1'bz;
  assign port_tran_so_dir        = 1'b0;  // SO is output only
  assign port_tran_si            = 1'bz;
  assign port_tran_si_dir        = 1'b0;  // SI is input only
  assign port_tran_sck           = 1'bz;
  assign port_tran_sck_dir       = 1'b0;  // clock direction can change
  assign port_tran_sd            = 1'bz;
  assign port_tran_sd_dir        = 1'b0;  // SD is input and not used

  // tie off the rest of the pins we are not using
  assign cram0_a                 = 'h0;
  assign cram0_dq                = {16{1'bZ}};
  assign cram0_clk               = 0;
  assign cram0_adv_n             = 1;
  assign cram0_cre               = 0;
  assign cram0_ce0_n             = 1;
  assign cram0_ce1_n             = 1;
  assign cram0_oe_n              = 1;
  assign cram0_we_n              = 1;
  assign cram0_ub_n              = 1;
  assign cram0_lb_n              = 1;

  assign cram1_a                 = 'h0;
  assign cram1_dq                = {16{1'bZ}};
  assign cram1_clk               = 0;
  assign cram1_adv_n             = 1;
  assign cram1_cre               = 0;
  assign cram1_ce0_n             = 1;
  assign cram1_ce1_n             = 1;
  assign cram1_oe_n              = 1;
  assign cram1_we_n              = 1;
  assign cram1_ub_n              = 1;
  assign cram1_lb_n              = 1;

  // assign dram_a                  = 'h0;
  // assign dram_ba                 = 'h0;
  // assign dram_dq                 = {16{1'bZ}};
  // assign dram_dqm                = 'h0;
  // assign dram_clk                = 'h0;
  // assign dram_cke                = 'h0;
  // assign dram_ras_n              = 'h1;
  // assign dram_cas_n              = 'h1;
  // assign dram_we_n               = 'h1;

  assign sram_a                  = 'h0;
  assign sram_dq                 = {16{1'bZ}};
  assign sram_oe_n               = 1;
  assign sram_we_n               = 1;
  assign sram_ub_n               = 1;
  assign sram_lb_n               = 1;

  assign dbg_tx                  = 1'bZ;
  assign user1                   = 1'bZ;
  assign aux_scl                 = 1'bZ;
  assign vpll_feed               = 1'bZ;


  // for bridge write data, we just broadcast it to all bus devices
  // for bridge read data, we have to mux it
  // add your own devices here
  always @(*) begin
    casex (bridge_addr)
      default: begin
        bridge_rd_data <= 0;
      end
      32'h2xxxxxxx: begin
        bridge_rd_data <= sd_read_data;
      end
      // The open_dataslot_file_t struct, which the host reads back out of us.
      32'h61xxxxxx: begin
        bridge_rd_data <= path_rd_data;
      end
      32'hF8xxxxxx: begin
        bridge_rd_data <= cmd_bridge_rd_data;
      end
    endcase
  end

  always @(posedge clk_74a) begin
    if (reset_delay > 0) begin
      reset_delay <= reset_delay - 1;
    end

    if (bridge_wr) begin
      casex (bridge_addr)
        32'h50: begin
          reset_delay <= 32'h100000;
        end
        32'h100: begin
          turbo_tap_enable <= bridge_wr_data[0];
        end
        32'h104: begin
          button6_enable <= bridge_wr_data[0];
        end
        32'h108: begin
          button1_turbo_speed <= bridge_wr_data[1:0];
        end
        32'h10C: begin
          button2_turbo_speed <= bridge_wr_data[1:0];
        end
        32'h200: begin
          overscan_enable <= bridge_wr_data[0];
        end
        32'h204: begin
          extra_sprites_enable <= bridge_wr_data[0];
        end
        32'h208: begin
          raw_rgb_enable <= bridge_wr_data[0];
        end
        32'h300: begin
          master_audio_boost <= bridge_wr_data[1:0];
        end
        32'h304: begin
          adpcm_audio_boost <= bridge_wr_data[0];
        end
        32'h308: begin
          cd_audio_boost <= bridge_wr_data[0];
        end
        // ROM loading options
        32'h400: begin
          swap_bits <= bridge_wr_data[0];
        end
        // Cheats
        32'h404: begin
          cheats_enabled <= bridge_wr_data[0];
        end
        32'h408: begin
          show_cheats <= bridge_wr_data[0];
        end
        // CD read probe, docs/CD-PLAN.md P0
        32'h40C: begin
          probe_start <= bridge_wr_data[0];
        end
        32'h410: begin
          probe_chunk <= bridge_wr_data[1:0];
        end
        32'h414: begin
          path_start <= bridge_wr_data[0];
        end
        // 32'h200: begin
        //   mb128_enable <= bridge_wr_data[0];
        // end
      endcase
    end
  end

  //
  // host/target command handler
  //
  wire reset_n;  // driven by host commands, can be used as core-wide reset
  wire [31:0] cmd_bridge_rd_data;

  // bridge host commands
  // synchronous to clk_74a
  wire status_boot_done = pll_core_locked;
  wire status_setup_done = pll_core_locked;  // rising edge triggers a target command
  wire status_running = reset_n;  // we are running as soon as reset_n goes high

  wire dataslot_requestread;
  wire [15:0] dataslot_requestread_id;
  wire dataslot_requestread_ack = 1;
  wire dataslot_requestread_ok = 1;

  wire dataslot_requestwrite;
  wire [15:0] dataslot_requestwrite_id;
  wire dataslot_requestwrite_ack = 1;
  wire dataslot_requestwrite_ok = 1;

  wire dataslot_allcomplete;

  wire savestate_supported;
  wire [31:0] savestate_addr;
  wire [31:0] savestate_size;
  wire [31:0] savestate_maxloadsize;

  wire savestate_start;
  wire savestate_start_ack;
  wire savestate_start_busy;
  wire savestate_start_ok;
  wire savestate_start_err;

  wire savestate_load;
  wire savestate_load_ack;
  wire savestate_load_busy;
  wire savestate_load_ok;
  wire savestate_load_err;

  wire osnotify_inmenu;

  // bridge target commands
  // synchronous to clk_74a

  // Set to 0 to take the SD read probe out of the build entirely: the module,
  // the target command traffic it generates and the overlay row that prints
  // its answer all fold away, because probe_read stops being driven and
  // cheat_osd's DIAG branch loses its inputs. This has to be 0 before anything
  // is released. See docs/CD-PLAN.md P0.
  localparam CD_PROBE = 1;

  wire         probe_req, path_req;
  wire [ 15:0] probe_cmd, path_cmd;
  wire [ 31:0] probe_p0, probe_p1, probe_p2, probe_p3;
  wire [ 31:0] path_p0, path_p1, path_p2, path_p3;
  wire [155:0] probe_line, path_line;
  wire         probe_valid, path_valid;
  wire [ 31:0] path_rd_data;

  // The sector fetcher and the audio ring, neither a diagnostic and neither
  // inside CD_PROBE.
  wire         audio_cmd_req;
  wire [ 15:0] audio_cmd;
  wire [ 31:0] audio_p0, audio_p1, audio_p2, audio_p3;

  wire         fetch_cmd_req;
  wire [ 15:0] fetch_cmd;
  wire [ 31:0] fetch_p0, fetch_p1, fetch_p2, fetch_p3;

  wire         tcmd_ack, tcmd_done;
  wire [ 15:0] tcmd_result;

  // The two diagnostics share one target command port. Ownership is latched
  // rather than taken from the live request lines, because a requester drops
  // its request the moment it is acknowledged: a plain `path_req ? ... :`
  // arbiter would hand the path probe's completion to the throughput probe,
  // which would read it as a request it never made finishing instantly.
  //
  // core_bridge_cmd holds ack up for the whole transaction, so ack low means
  // idle, and sel_path tracks the request lines only while idle and freezes
  // for the duration. The loser keeps its request asserted and wins the next
  // one. Priority while idle goes to the path probe, arbitrarily; they are
  // separate menu switches and are not expected to run together.
  // Three requesters now: the throughput probe, the path prober and the sector
  // fetcher. Ownership is latched while the port is idle and frozen for the
  // transaction, for the reason P1 recorded: a requester drops its request the
  // instant it is acknowledged, so selecting on the live lines hands one
  // module's completion to another. The fetcher wins ties because it is the
  // only one a running game depends on; the other two are diagnostics.
  // Audio outranks the sector fetch. It only asks when a chunk of its ring has
  // freed, which is once every 11.6 ms, so it takes about a fifth of the
  // transport and leaves the rest to data. The other way round, a long READ6
  // burst would hold the port for hundreds of milliseconds and drain a ring
  // that only holds 93.
  localparam [1:0] OWN_PROBE = 2'd0, OWN_PATH = 2'd1, OWN_FETCH = 2'd2,
                   OWN_AUDIO = 2'd3;

  reg [1:0] tcmd_own = OWN_PROBE;
  always @(posedge clk_74a) begin
    if (!tcmd_ack)
      tcmd_own <= audio_cmd_req ? OWN_AUDIO
                : fetch_cmd_req ? OWN_FETCH
                : path_req      ? OWN_PATH : OWN_PROBE;
  end

  wire sel_path  = (tcmd_own == OWN_PATH);
  wire sel_fetch = (tcmd_own == OWN_FETCH);
  wire sel_audio = (tcmd_own == OWN_AUDIO);

  // The request is taken through the same select as the parameters, not ORed
  // past it. sel_path is a register, so it settles a cycle after a requester
  // raises its request; with `path_req | probe_req` here, core_bridge_cmd
  // accepts that first cycle and latches the parameters of whichever module
  // sel_path was still pointing at. The path probe's very first command went
  // out as the throughput probe's 0x0180 with four zero parameters, which
  // returned 0, so the path probe recorded a successful 0x0190 and then read
  // an untouched buffer: G0 with L000 and a malformed path from 0x0192. A
  // false pass, which is worse than a failure.
  //
  // Selecting the request too means an unsettled cycle presents the idle
  // module's request, which is low, so nothing is issued until the select
  // agrees with the requester. It costs one cycle and cannot misissue.
  wire         tcmd_req = sel_audio ? audio_cmd_req
                        : sel_fetch ? fetch_cmd_req : sel_path ? path_req : probe_req;
  wire [ 15:0] tcmd     = sel_audio ? audio_cmd
                        : sel_fetch ? fetch_cmd : sel_path ? path_cmd : probe_cmd;
  wire [ 31:0] tcmd_p0  = sel_audio ? audio_p0
                        : sel_fetch ? fetch_p0 : sel_path ? path_p0 : probe_p0;
  wire [ 31:0] tcmd_p1  = sel_audio ? audio_p1
                        : sel_fetch ? fetch_p1 : sel_path ? path_p1 : probe_p1;
  wire [ 31:0] tcmd_p2  = sel_audio ? audio_p2
                        : sel_fetch ? fetch_p2 : sel_path ? path_p2 : probe_p2;
  wire [ 31:0] tcmd_p3  = sel_audio ? audio_p3
                        : sel_fetch ? fetch_p3 : sel_path ? path_p3 : probe_p3;

  // The bin has to be opened before a single sector can be read, and for two
  // builds nothing did it: `path_start` is written only from bridge 0x414, the
  // debug menu toggle, so unless somebody ran the probe by hand slot 101 was
  // never opened. Every 0x0180 against it returned an error into a buffer
  // nobody had written, the drive pushed 2048 zero bytes, and the System Card
  // said LOAD ERROR. The fetch counter still climbed, because the command did
  // complete: it completed unsuccessfully.
  //
  // So this is no longer a diagnostic and no longer sits inside CD_PROBE. It
  // runs from the cue being parsed, which is the event that means slot 100
  // holds a path worth reading, and the menu toggle is kept only so the chain
  // can still be re-run by hand.
  wire cue_loaded;              // assigned beside cd_toc, below
  wire toc_ready_74;
  synch_3 s_tocrdy (
      cue_loaded,
      toc_ready_74,
      clk_74a
  );

  reg  toc_ready_74_d = 0;
  reg  path_auto = 0;
  always @(posedge clk_74a) begin
    toc_ready_74_d <= toc_ready_74;
    path_auto      <= toc_ready_74 & ~toc_ready_74_d;
  end

  // The open runs on its own at every cue load now, so `path_valid` is high in
  // normal operation and can no longer be read as "the path prober has an
  // answer worth showing". Only a run started from the menu claims the
  // overlay; an automatic one leaves the drive rows on screen.
  reg path_manual = 0;
  always @(posedge clk_74a) begin
    if (path_start) path_manual <= 1'b1;
    else if (path_auto) path_manual <= 1'b0;
  end

  wire path_show = path_manual & (path_valid | path_start);

  dataslot_path path (
      .clk  (clk_74a),
      .reset(~pll_core_locked),

      .start(path_start | path_auto),

      .bridge_addr   (bridge_addr),
      .bridge_wr     (bridge_wr),
      .bridge_wr_data(bridge_wr_data),
      .bridge_rd     (bridge_rd),
      .bridge_rd_data(path_rd_data),

      .cmd_req   (path_req),
      .cmd       (path_cmd),
      .cmd_p0    (path_p0),
      .cmd_p1    (path_p1),
      .cmd_p2    (path_p2),
      .cmd_p3    (path_p3),
      .cmd_ack   (tcmd_ack & sel_path),
      .cmd_done  (tcmd_done & sel_path),
      .cmd_result(tcmd_result),

      .line (path_line),
      .valid(path_valid)
  );

  generate
    if (CD_PROBE) begin : g_probe
      dataslot_probe probe (
          .clk  (clk_74a),
          .reset(~pll_core_locked),

          .start    (probe_start),
          .chunk_sel(probe_chunk),

          .bridge_addr(bridge_addr),
          .bridge_wr  (bridge_wr),

          .cmd_req   (probe_req),
          .cmd       (probe_cmd),
          .cmd_p0    (probe_p0),
          .cmd_p1    (probe_p1),
          .cmd_p2    (probe_p2),
          .cmd_p3    (probe_p3),
          .cmd_ack   (tcmd_ack & (tcmd_own == OWN_PROBE)),
          .cmd_done  (tcmd_done & (tcmd_own == OWN_PROBE)),
          .cmd_result(tcmd_result),

          .line (probe_line),
          .valid(probe_valid)
      );

    end else begin : g_no_probe
      assign probe_req    = 0;
      assign probe_cmd    = 0;
      assign probe_p0     = 0;
      assign probe_p1     = 0;
      assign probe_p2     = 0;
      assign probe_p3     = 0;
      assign probe_line   = 0;
      assign probe_valid  = 0;
    end
  endgenerate

  // Whichever diagnostic last produced an answer. The path probe wins while it
  // is running so that starting it clears the throughput line rather than
  // leaving a stale number on screen next to fresh result codes.
  wire [155:0] diag_line_sel  = path_show ? path_line  : probe_line;
  wire         diag_valid_sel = path_show ? path_valid : probe_valid;

  // The two probes live in clk_74a and everything else in clk_sys_42_95, so
  // one 157 bit crossing brings them together and the whole block is then
  // composed in one clock. A diagnostic finishes its counters a cycle before
  // it sets valid and holds them until the next run, so the data has settled
  // long before valid works its way through the same three stages.
  wire         diag_valid_s;
  wire [155:0] diag_line_s;

  synch_3 #(
      .WIDTH(157)
  ) diag_s (
      {diag_valid_sel, diag_line_sel},
      {diag_valid_s, diag_line_s},
      clk_sys_42_95
  );

  // Priority: whichever probe was last run, then the drive model once a disc
  // is loaded, then the track table. None of the three needs a menu switch of
  // its own, which matters at 15 of APF's 16 menu variables. The drive block
  // carries the track count in its first field, so promoting it above the TOC
  // line loses nothing the TOC line was there to show.
  //
  // The probes and the TOC each compose one row and draw at the top with the
  // rest of the block blank. Font index 0 is a space, so padding with zeroes
  // is padding with blanks.
  wire [935:0] osd_diag_line  = diag_valid_s ? {diag_line_s, 780'd0}
                              : cd_enable    ? cd_host_line
                              :                {toc_line, 780'd0};
  wire         osd_diag_valid = diag_valid_s | cd_enable | toc_line_valid;

  // And into the video clock a character at a time rather than all at once.
  // Carrying the block as a bus was 2811 registers crossing the die and cost
  // about a nanosecond of setup slack; the overlay reads characters anyway.
  wire [7:0] osd_diag_raddr;
  wire [5:0] osd_diag_rchar;
  wire       osd_diag_valid_v;

  cd_diag cd_diag (
      .clk_sys(clk_sys_42_95),
      .block  (osd_diag_line),
      .valid  (osd_diag_valid),

      .clk_osd  (clk_mem_85_91),
      .raddr    (osd_diag_raddr),
      .rchar    (osd_diag_rchar),
      .valid_osd(osd_diag_valid_v)
  );

  // bridge data slot access

  reg [9:0] datatable_addr;
  reg datatable_wren;
  reg [31:0] datatable_data;
  wire [31:0] datatable_q;

  core_bridge_cmd icb (

      .clk    (clk_74a),
      .reset_n(reset_n),

      .bridge_endian_little(bridge_endian_little),
      .bridge_addr         (bridge_addr),
      .bridge_rd           (bridge_rd),
      .bridge_rd_data      (cmd_bridge_rd_data),
      .bridge_wr           (bridge_wr),
      .bridge_wr_data      (bridge_wr_data),

      .status_boot_done (status_boot_done),
      .status_setup_done(status_setup_done),
      .status_running   (status_running),

      .dataslot_requestread    (dataslot_requestread),
      .dataslot_requestread_id (dataslot_requestread_id),
      .dataslot_requestread_ack(dataslot_requestread_ack),
      .dataslot_requestread_ok (dataslot_requestread_ok),

      .dataslot_requestwrite    (dataslot_requestwrite),
      .dataslot_requestwrite_id (dataslot_requestwrite_id),
      .dataslot_requestwrite_ack(dataslot_requestwrite_ack),
      .dataslot_requestwrite_ok (dataslot_requestwrite_ok),

      .dataslot_allcomplete(dataslot_allcomplete),

      .target_cmd_req   (tcmd_req),
      .target_cmd       (tcmd),
      .target_cmd_p0    (tcmd_p0),
      .target_cmd_p1    (tcmd_p1),
      .target_cmd_p2    (tcmd_p2),
      .target_cmd_p3    (tcmd_p3),
      .target_cmd_ack   (tcmd_ack),
      .target_cmd_done  (tcmd_done),
      .target_cmd_result(tcmd_result),

      .savestate_supported  (savestate_supported),
      .savestate_addr       (savestate_addr),
      .savestate_size       (savestate_size),
      .savestate_maxloadsize(savestate_maxloadsize),

      .savestate_start     (savestate_start),
      .savestate_start_ack (savestate_start_ack),
      .savestate_start_busy(savestate_start_busy),
      .savestate_start_ok  (savestate_start_ok),
      .savestate_start_err (savestate_start_err),

      .savestate_load     (savestate_load),
      .savestate_load_ack (savestate_load_ack),
      .savestate_load_busy(savestate_load_busy),
      .savestate_load_ok  (savestate_load_ok),
      .savestate_load_err (savestate_load_err),

      .osnotify_inmenu(osnotify_inmenu),

      .datatable_addr(datatable_addr),
      .datatable_wren(datatable_wren),
      .datatable_data(datatable_data),
      .datatable_q   (datatable_q)
  );

  // Which slot APF is currently streaming.
  //
  // Upstream drove these from bridge writes at 0x0, 0x4 and 0x8, issued by the
  // chip32 VM program in support/chip32.asm. That program loads slot 0 and
  // slot 1 by name and then exits, so a third slot could never be delivered:
  // with a chip32 program present APF loads only what the program asks for.
  // The GB/GBC fork ships no chip32 at all, which is why the same Cheats slot
  // declaration works there, and it is why this core no longer ships one
  // either. APF now loads every declared slot itself and these follow the
  // dataslot handshake instead.
  //
  // The only other thing the program did was sniff the ROM extension to set
  // is_sgx, which is dead here: SGX_EN is 0, so main.sv ands it away.
  reg any_download = 0;
  always @(posedge clk_74a) begin
    if (dataslot_requestwrite) any_download <= 1;
    else if (dataslot_allcomplete) any_download <= 0;
  end

  wire ioctl_download = any_download && dataslot_requestwrite_id == 16'd0;
  wire save_download  = any_download && dataslot_requestwrite_id == 16'd1;
  wire is_sgx = 1'b0;
  reg swap_bits = 0;
  wire ioctl_wr;
  wire [23:0] ioctl_addr;
  wire [15:0] ioctl_dout;

  // always @(posedge clk_74a) begin
  //   if (dataslot_requestwrite) ioctl_download <= 1;
  //   else if (dataslot_allcomplete) ioctl_download <= 0;
  // end

  wire [31:0] sd_read_data;

  wire sd_rd;
  wire sd_wr;
  wire [15:0] sd_buff_din;
  wire [15:0] sd_buff_dout;

  wire [24:0] sd_buff_addr = sd_wr ? sd_buff_addr_in : sd_buff_addr_out;
  wire [24:0] sd_buff_addr_in;
  wire [24:0] sd_buff_addr_out;

  // wire save_loading = dataslot_requestwrite_id == 1 || dataslot_requestread_id == 1;

  wire ioctl_download_s;
  wire save_download_s;
  wire is_sgx_s;
  wire swap_bits_s;
  // Declared here rather than with the other settings below, because the
  // synchroniser just under this line uses it.
  reg  show_cheats = 0;
  wire show_cheats_v;   // show_cheats in the video clock domain

  synch_3 #(
      .WIDTH(5)
  ) download_s (
      {ioctl_download, save_download, is_sgx, swap_bits, show_cheats},
      {ioctl_download_s, save_download_s, is_sgx_s, swap_bits_s, show_cheats_v},
      clk_mem_85_91
  );

  always @(posedge clk_74a or negedge pll_core_locked) begin
    if (~pll_core_locked) begin
      datatable_addr <= 0;
      datatable_data <= 0;
      datatable_wren <= 0;
    end else begin
      // Write sram size
      datatable_wren <= 1;

      datatable_data <= mb128_enable ? 32'h20000 : 32'h800;
      // Data slot index 1, not id 1
      datatable_addr <= 1 * 2 + 1;
    end
  end

  data_loader #(
      .ADDRESS_MASK_UPPER_4(4'h1),
      .ADDRESS_SIZE(24),
      .OUTPUT_WORD_SIZE(2),

      .WRITE_MEM_CLOCK_DELAY(32),
      .WRITE_MEM_EN_CYCLE_LENGTH(16)
  ) data_loader (
      .clk_74a(clk_74a),
      .clk_memory(clk_mem_85_91),

      .bridge_wr(bridge_wr),
      .bridge_endian_little(bridge_endian_little),
      .bridge_addr(bridge_addr),
      .bridge_wr_data(bridge_wr_data),

      .write_en  (ioctl_wr),
      .write_addr(ioctl_addr),
      .write_data(ioctl_dout)
  );

  data_loader #(
      .ADDRESS_MASK_UPPER_4(4'h2),
      .ADDRESS_SIZE(24),
      .OUTPUT_WORD_SIZE(2),

      .WRITE_MEM_CLOCK_DELAY(16),
      .WRITE_MEM_EN_CYCLE_LENGTH(8)
  ) save_data_loader (
      .clk_74a(clk_74a),
      .clk_memory(clk_sys_42_95),

      .bridge_wr(bridge_wr),
      .bridge_endian_little(bridge_endian_little),
      .bridge_addr(bridge_addr),
      .bridge_wr_data(bridge_wr_data),

      .write_en  (sd_wr),
      .write_addr(sd_buff_addr_in),
      .write_data(sd_buff_dout)
  );

  // ------------------------------------------------------------------
  // Cheats. Data slot 2 streams a libretro .cht file to 0x5xxxxxxx one byte at
  // a time; cheat_loader parses the ASCII as it arrives and writes the usable
  // codes into cheat_poker's table. See docs/CHEATS.md.
  //
  // OUTPUT_WORD_SIZE 1 means four FIFO entries per 32-bit APF word, and APF
  // delivers a word roughly every 75 clk_74a cycles, so the drain has to stay
  // ahead of that. The default delay of 4 gives 16 clk_sys cycles per word,
  // comfortably ahead; the 32 used for the ROM loader above would not be.
  // ------------------------------------------------------------------
  wire       cheat_wr;
  wire [7:0] cheat_dout;

  data_loader #(
      .ADDRESS_MASK_UPPER_4(4'h5),
      .ADDRESS_SIZE(24),
      .OUTPUT_WORD_SIZE(1),
      .WRITE_MEM_CLOCK_DELAY(4),
      .WRITE_MEM_EN_CYCLE_LENGTH(1)
  ) cheat_data_loader (
      .clk_74a(clk_74a),
      .clk_memory(clk_sys_42_95),

      .bridge_wr(bridge_wr),
      .bridge_endian_little(bridge_endian_little),
      .bridge_addr(bridge_addr),
      .bridge_wr_data(bridge_wr_data),

      .write_en  (cheat_wr),
      .write_addr(),
      .write_data(cheat_dout)
  );

  // ------------------------------------------------------------------
  // The drive. docs/CD-PLAN.md P3.
  //
  // cd_host runs on clk_sys_42_95 because that is cd.vhd's clock, and cd_fetch
  // straddles the two domains: the transport it uses lives on clk_74a with the
  // bridge. A whole sector is buffered before the drive model is told it has
  // one, because a short read is indistinguishable from a successful one.
  wire [ 6:0] toc_rd_track;
  wire [31:0] toc_rd_lba, toc_rd_base;
  wire [11:0] toc_rd_size;
  wire        toc_rd_audio;

  wire [95:0] cd_comm;
  wire        cd_comm_send;
  wire [ 7:0] cd_stat, cd_msg, cd_data;
  wire        cd_stat_get, cd_dout_req, cd_data_wr, cd_audio_wr;
  wire [79:0] cd_dout;
  wire        cd_dout_send, cd_data_end, cd_dm, cd_region, cd_reset_lvl;

  wire        cd_fetch_req, cd_fetch_done;
  wire [31:0] cd_fetch_offset;
  wire [10:0] cd_sec_addr;
  wire [ 7:0] cd_sec_data;
  wire [ 3:0] cd_fetch_err;
  wire [ 3:0] cd_fetch_err_sys;

  wire        cd_aud_play, cd_aud_restart, cd_aud_ended;
  wire [31:0] cd_aud_start, cd_aud_end;
  wire [ 3:0] cd_aud_level;
  wire [ 3:0] cd_aud_err, cd_aud_wr_dbg, cd_aud_rd_dbg, cd_aud_room;
  wire [15:0] cd_aud_ok, cd_aud_bad, cd_aud_secs;
  wire [31:0] cd_aud_head;
  wire [ 7:0] cd_aud_data;
  wire        cd_aud_req, cd_aud_busy, cd_aud_dm;

  // A cue with tracks in it is a disc. cd_en is a per-load mode bit rather
  // than a setting: K[7] of the joypad port is `not CD_EN`, the CD-unit
  // presence flag, so leaving it set for a HuCard makes a game that checks it
  // take the CD path and find nothing. See docs/CD-PLAN.md 5e.
  assign cue_loaded = (toc_track_count != 7'd0);
  wire   cd_enable  = cue_loaded;

  // The open has to have happened before the first sector is asked for. In
  // practice it always has, by three orders of magnitude: the chain runs the
  // moment the cue parses and the System Card is hundreds of milliseconds from
  // its first READ6. The gate is here so the dependency is in the RTL rather
  // than in the timing, and so a failed open stalls in S_FETCH where the
  // overlay shows it, instead of serving zeroes that look like data.
  wire bin_ready;
  synch_3 s_binrdy (
      path_valid,
      bin_ready,
      clk_sys_42_95
  );

  wire [935:0] cd_host_line;

  cd_host cd_host (
      .clk  (clk_sys_42_95),
      .reset(cue_reset),
      .cd_en(cd_enable),

      .comm     (cd_comm),
      .comm_send(cd_comm_send),
      .stat     (cd_stat),
      .msg      (cd_msg),
      .stat_get (cd_stat_get),
      .dout_req (cd_dout_req),
      .dout     (cd_dout),
      .dout_send(cd_dout_send),
      .data     (cd_data),
      .data_wr  (cd_data_wr),
      .audio_wr (cd_audio_wr),
      .data_end (cd_data_end),
      .dm       (cd_dm),
      .cd_reset (cd_reset_lvl),
      .region   (cd_region),

      .toc_track  (toc_rd_track),
      .toc_lba    (toc_rd_lba),
      .toc_base   (toc_rd_base),
      .toc_size   (toc_rd_size),
      .toc_audio  (toc_rd_audio),
      .track_count(toc_track_count),
      .toc_end    (toc_end),

      .fetch_req   (cd_fetch_req),
      .fetch_offset(cd_fetch_offset),
      .fetch_done  (cd_fetch_done),
      .sec_addr    (cd_sec_addr),
      .sec_data    (cd_sec_data),

      .fetch_err(cd_fetch_err_sys),

      .aud_play   (cd_aud_play),
      .aud_restart(cd_aud_restart),
      .aud_start  (cd_aud_start),
      .aud_end    (cd_aud_end),
      .aud_ended  (cd_aud_ended),
      .aud_level  (cd_aud_level),
      .aud_err    (cd_aud_err),
      .aud_wr     (cd_aud_wr_dbg),
      .aud_rd     (cd_aud_rd_dbg),
      .aud_room   (cd_aud_room),
      .aud_ok     (cd_aud_ok),
      .aud_bad    (cd_aud_bad),
      .aud_secs   (cd_aud_secs),
      .aud_head   (cd_aud_head),
      .aud_data   (cd_aud_data),
      .aud_req    (cd_aud_req),
      .aud_busy   (cd_aud_busy),
      .aud_dm     (cd_aud_dm),

      .line(cd_host_line)
  );

  cd_audio cd_audio (
      .clk_74a(clk_74a),
      .clk_sys(clk_sys_42_95),
      .reset  (cue_reset),

      .play     (cd_aud_play),
      .restart  (cd_aud_restart),
      .start_off(cd_aud_start),
      .end_off  (cd_aud_end),
      .ended    (cd_aud_ended),

      .aud_data(cd_aud_data),
      .aud_req (cd_aud_req),
      .aud_busy(cd_aud_busy),
      .aud_dm  (cd_aud_dm),

      .bridge_addr   (bridge_addr),
      .bridge_wr     (bridge_wr),
      .bridge_wr_data(bridge_wr_data),

      .cmd_req   (audio_cmd_req),
      .cmd       (audio_cmd),
      .cmd_p0    (audio_p0),
      .cmd_p1    (audio_p1),
      .cmd_p2    (audio_p2),
      .cmd_p3    (audio_p3),
      .cmd_ack   (tcmd_ack & sel_audio),
      .cmd_done  (tcmd_done & sel_audio),
      .cmd_result(tcmd_result),

      .level   (cd_aud_level),
      .dbg_wr  (cd_aud_wr_dbg),
      .dbg_rd  (cd_aud_rd_dbg),
      .dbg_room(cd_aud_room),
      .dbg_ok  (cd_aud_ok),
      .dbg_bad (cd_aud_bad),
      .dbg_secs(cd_aud_secs),
      .dbg_head(cd_aud_head),
      .err     (cd_aud_err)
  );

  synch_3 #(
      .WIDTH(4)
  ) s_ferr (
      cd_fetch_err,
      cd_fetch_err_sys,
      clk_sys_42_95
  );

  cd_fetch cd_fetch (
      .clk_74a(clk_74a),
      .clk_sys(clk_sys_42_95),
      .reset  (~pll_core_locked),

      .ready   (bin_ready),
      .req     (cd_fetch_req),
      .offset  (cd_fetch_offset),
      .done    (cd_fetch_done),
      .sec_addr(cd_sec_addr),
      .sec_data(cd_sec_data),

      .bridge_addr   (bridge_addr),
      .bridge_wr     (bridge_wr),
      .bridge_wr_data(bridge_wr_data),

      .cmd_req   (fetch_cmd_req),
      .cmd       (fetch_cmd),
      .cmd_p0    (fetch_p0),
      .cmd_p1    (fetch_p1),
      .cmd_p2    (fetch_p2),
      .cmd_p3    (fetch_p3),
      .cmd_ack   (tcmd_ack & sel_fetch),
      .cmd_done  (tcmd_done & sel_fetch),
      .cmd_result(tcmd_result),

      .err(cd_fetch_err)
  );

  // A cheat file belongs to the game it was loaded for, so the parser restarts
  // whenever a new cheat file or a new ROM starts arriving, and at core reset.
  // The reset term is not optional: without it the parser could reach the poker
  // having never been reset, and a stray code_wr puts a poke in work RAM.
  wire cheat_download = any_download && dataslot_requestwrite_id == 16'd2;

  // Edge-detect off the second and third synchroniser stages rather than the
  // first: cheat_download and ioctl_download are combinational from a compare
  // in the clk_74a domain, and this pulse resets every register in the path.
  reg cheat_dl_s, cheat_dl_s2, cheat_dl_s3;
  reg cart_dl_s, cart_dl_s2, cart_dl_s3;
  always @(posedge clk_sys_42_95) begin
    cheat_dl_s  <= cheat_download;
    cheat_dl_s2 <= cheat_dl_s;
    cheat_dl_s3 <= cheat_dl_s2;
    cart_dl_s   <= ioctl_download;
    cart_dl_s2  <= cart_dl_s;
    cart_dl_s3  <= cart_dl_s2;
  end

  // A cheat file can arrive after the ROM, so the poker has to be held off
  // while the table is being rewritten under it. Without this it can spend a
  // frame poking a half-loaded table: a stale address with a fresh value.
  wire cheat_busy = cheat_dl_s2;

  wire cheat_reset = ~reset_n
                   | (cheat_dl_s2 & ~cheat_dl_s3)
                   | (cart_dl_s2  & ~cart_dl_s3);

  wire       cheat_code_wr;
  wire [4:0] cheat_code_index;
  wire [12:0] cheat_code_addr;
  wire [7:0] cheat_code_data;
  wire [5:0] cheat_code_total;
  wire [5:0] cheat_group_count;
  wire [19:0] cheat_byte_count;
  wire        cheat_desc_wr, cheat_desc_end;
  wire  [4:0] cheat_desc_group, cheat_desc_col;
  wire  [5:0] cheat_desc_char;
  wire  [5:0] cheat_title_count;

  cheat_loader #(
      .MAX_CODES(32),
      .INDEX_W  (5)
  ) cheat_loader (
      .clk        (clk_sys_42_95),
      .reset      (cheat_reset),
      .wr         (cheat_wr),
      .data       (cheat_dout),
      .code_wr    (cheat_code_wr),
      .code_index (cheat_code_index),
      .code_addr  (cheat_code_addr),
      .code_data  (cheat_code_data),
      .code_total (cheat_code_total),
      .desc_wr    (cheat_desc_wr),
      .desc_group (cheat_desc_group),
      .desc_col   (cheat_desc_col),
      .desc_char  (cheat_desc_char),
      .desc_end   (cheat_desc_end),
      .title_count(cheat_title_count),
      .group_count(cheat_group_count),
      .byte_count (cheat_byte_count)
  );

  // ------------------------------------------------------------------
  // The cue sheet, parsed into a track table. docs/CD-PLAN.md P2.
  //
  // Slot 100 is preloaded rather than deferload: deferload is right for the
  // 489MB bin, which cannot fit anywhere, and wrong for a 975 byte cue, whose
  // bytes have to reach the core to be parsed at all. Only slot 101 defers.
  //
  // WRITE_MEM_CLOCK_DELAY 4 and WRITE_MEM_EN_CYCLE_LENGTH 1 as the cheat
  // loader uses, not the ROM loader's 32 and 16: APF delivers a 32-bit word
  // about every 75 clk_74a cycles and a byte-wide drain has to stay ahead.
  wire       cue_wr;
  wire [7:0] cue_dout;

  data_loader #(
      .ADDRESS_MASK_UPPER_4(4'h3),
      .ADDRESS_SIZE(24),
      .OUTPUT_WORD_SIZE(1),
      .WRITE_MEM_CLOCK_DELAY(4),
      .WRITE_MEM_EN_CYCLE_LENGTH(1)
  ) cue_data_loader (
      .clk_74a(clk_74a),
      .clk_memory(clk_sys_42_95),

      .bridge_wr(bridge_wr),
      .bridge_endian_little(bridge_endian_little),
      .bridge_addr(bridge_addr),
      .bridge_wr_data(bridge_wr_data),

      .write_en  (cue_wr),
      .write_addr(),
      .write_data(cue_dout)
  );

  wire cue_download = any_download && dataslot_requestwrite_id == 16'd100;

  reg cue_dl_s, cue_dl_s2, cue_dl_s3;
  always @(posedge clk_sys_42_95) begin
    cue_dl_s  <= cue_download;
    cue_dl_s2 <= cue_dl_s;
    cue_dl_s3 <= cue_dl_s2;
  end

  // Same shape as cheat_reset: a new cue, or a new ROM, or core reset. Edge
  // taken off the later synchroniser stages because cue_download is a
  // combinational compare in the clk_74a domain.
  wire cue_reset = ~reset_n | (cue_dl_s2 & ~cue_dl_s3) | (cart_dl_s2 & ~cart_dl_s3);

  wire [  6:0] toc_track_count;
  wire [ 31:0] toc_end;
  wire [155:0] toc_line;
  wire         toc_line_valid;

  cd_toc #(
      .MAX_TRACKS(99)
  ) cd_toc (
      .clk  (clk_sys_42_95),
      .reset(cue_reset),
      .wr   (cue_wr),
      .data (cue_dout),

      // Read by the drive model. Until P3 this was parked on the last track
      // parsed, purely to stop Quartus deleting the memories as unused.
      .rd_track(toc_rd_track),
      .rd_lba  (toc_rd_lba),
      .rd_base (toc_rd_base),
      .rd_size (toc_rd_size),
      .rd_audio(toc_rd_audio),

      .track_count(toc_track_count),
      .toc_end    (toc_end),
      .line       (toc_line),
      .line_valid (toc_line_valid)
  );


  data_unloader #(
      .ADDRESS_MASK_UPPER_4(4'h2),
      .ADDRESS_SIZE(25),
      .INPUT_WORD_SIZE(2),

      .READ_MEM_CLOCK_DELAY(16)
  ) save_data_unloader (
      .clk_74a(clk_74a),
      .clk_memory(clk_sys_42_95),

      .bridge_rd(bridge_rd),
      .bridge_endian_little(bridge_endian_little),
      .bridge_addr(bridge_addr),
      .bridge_rd_data(sd_read_data),

      .read_en  (sd_rd),
      .read_addr(sd_buff_addr_out),
      .read_data(sd_buff_din)
  );

  wire [15:0] cont1_key_s;
  wire [15:0] cont2_key_s;
  wire [15:0] cont3_key_s;
  wire [15:0] cont4_key_s;

  synch_3 #(
      .WIDTH(16)
  ) cont1_s (
      cont1_key,
      cont1_key_s,
      clk_sys_42_95
  );

  synch_3 #(
      .WIDTH(16)
  ) cont2_s (
      cont2_key,
      cont2_key_s,
      clk_sys_42_95
  );

  synch_3 #(
      .WIDTH(16)
  ) cont3_s (
      cont3_key,
      cont3_key_s,
      clk_sys_42_95
  );

  synch_3 #(
      .WIDTH(16)
  ) cont4_s (
      cont4_key,
      cont4_key_s,
      clk_sys_42_95
  );

  // Settings

  reg turbo_tap_enable = 0;
  reg button6_enable = 0;
  reg [1:0] button1_turbo_speed = 0;
  reg [1:0] button2_turbo_speed = 0;

  reg overscan_enable = 0;
  reg extra_sprites_enable = 0;
  reg raw_rgb_enable = 0;
  reg mb128_enable = 0;
  reg cheats_enabled = 0;

  reg cd_audio_boost = 0;
  reg adpcm_audio_boost = 0;
  reg [1:0] master_audio_boost = 0;

  reg [31:0] reset_delay = 0;

  // The menu switch that runs the SD read probe. Held rather than pulsed: the
  // probe edge-detects it, and clearing it releases the result. probe_chunk
  // picks the request size, so one build sweeps all three. See CD_PROBE and
  // docs/CD-PLAN.md P0.
  reg probe_start = 0;
  reg [1:0] probe_chunk = 0;
  reg path_start = 0;

  // Sync

  wire turbo_tap_enable_s;
  wire button6_enable_s;
  wire [1:0] button1_turbo_speed_s;
  wire [1:0] button2_turbo_speed_s;

  wire overscan_enable_s;
  wire extra_sprites_enable_s;
  wire raw_rgb_enable_s;
  wire mb128_enable_s;
  wire cheats_enabled_s;

  wire cd_audio_boost_s;
  wire adpcm_audio_boost_s;
  wire [1:0] master_audio_boost_s;

  synch_3 #(
      .WIDTH(15)
  ) settings_s (
      {
        turbo_tap_enable,
        button6_enable,
        button1_turbo_speed,
        button2_turbo_speed,
        overscan_enable,
        extra_sprites_enable,
        raw_rgb_enable,
        mb128_enable,
        cheats_enabled,
        cd_audio_boost,
        adpcm_audio_boost,
        master_audio_boost
      },
      {
        turbo_tap_enable_s,
        button6_enable_s,
        button1_turbo_speed_s,
        button2_turbo_speed_s,
        overscan_enable_s,
        extra_sprites_enable_s,
        raw_rgb_enable_s,
        mb128_enable_s,
        cheats_enabled_s,
        cd_audio_boost_s,
        adpcm_audio_boost_s,
        master_audio_boost_s
      },
      clk_sys_42_95
  );

  wire [15:0] audio_l;
  wire [15:0] audio_r;

  wire [1:0] dotclock_divider;
  wire border;

  pce pce (
      .clk_sys_42_95(clk_sys_42_95),
      .clk_mem_85_91(clk_mem_85_91),

      .core_reset(~reset_n || reset_delay > 0),
      .pll_core_locked(pll_core_locked),

      .sgx(is_sgx_s),
      .swap_bits(swap_bits_s),

      // Input
      .p1_button_1(cont1_key_s[4]),
      .p1_button_2(cont1_key_s[5]),
      .p1_button_3(cont1_key_s[6]),
      .p1_button_4(cont1_key_s[7]),
      .p1_button_5(cont1_key_s[8]),
      .p1_button_6(cont1_key_s[9]),
      .p1_button_select(cont1_key_s[14]),
      .p1_button_start(cont1_key_s[15]),
      .p1_dpad_up(cont1_key_s[0]),
      .p1_dpad_down(cont1_key_s[1]),
      .p1_dpad_left(cont1_key_s[2]),
      .p1_dpad_right(cont1_key_s[3]),

      .p2_button_1(cont2_key_s[4]),
      .p2_button_2(cont2_key_s[5]),
      .p2_button_3(cont2_key_s[6]),
      .p2_button_4(cont2_key_s[7]),
      .p2_button_5(cont2_key_s[8]),
      .p2_button_6(cont2_key_s[9]),
      .p2_button_select(cont2_key_s[14]),
      .p2_button_start(cont2_key_s[15]),
      .p2_dpad_up(cont2_key_s[0]),
      .p2_dpad_down(cont2_key_s[1]),
      .p2_dpad_left(cont2_key_s[2]),
      .p2_dpad_right(cont2_key_s[3]),

      .p3_button_1(cont3_key_s[4]),
      .p3_button_2(cont3_key_s[5]),
      .p3_button_3(cont3_key_s[6]),
      .p3_button_4(cont3_key_s[7]),
      .p3_button_5(cont3_key_s[8]),
      .p3_button_6(cont3_key_s[9]),
      .p3_button_select(cont3_key_s[14]),
      .p3_button_start(cont3_key_s[15]),
      .p3_dpad_up(cont3_key_s[0]),
      .p3_dpad_down(cont3_key_s[1]),
      .p3_dpad_left(cont3_key_s[2]),
      .p3_dpad_right(cont3_key_s[3]),

      .p4_button_1(cont4_key_s[4]),
      .p4_button_2(cont4_key_s[5]),
      .p4_button_3(cont4_key_s[6]),
      .p4_button_4(cont4_key_s[7]),
      .p4_button_5(cont4_key_s[8]),
      .p4_button_6(cont4_key_s[9]),
      .p4_button_select(cont4_key_s[14]),
      .p4_button_start(cont4_key_s[15]),
      .p4_dpad_up(cont4_key_s[0]),
      .p4_dpad_down(cont4_key_s[1]),
      .p4_dpad_left(cont4_key_s[2]),
      .p4_dpad_right(cont4_key_s[3]),

      // Settings
      .turbo_tap_enable(turbo_tap_enable_s),
      .button6_enable(button6_enable_s),
      .button1_turbo_speed(button1_turbo_speed_s),
      .button2_turbo_speed(button2_turbo_speed_s),

      .overscan_enable(overscan_enable_s),
      .extra_sprites_enable(extra_sprites_enable_s),
      .raw_rgb_enable(raw_rgb_enable_s),

      .cheats_enabled(cheats_enabled_s),
      .cheat_busy(cheat_busy),

      .cheat_code_wr(cheat_code_wr),
      .cheat_code_index(cheat_code_index),
      .cheat_code_addr(cheat_code_addr),
      .cheat_code_data(cheat_code_data),
      .cheat_code_total(cheat_code_total),

      .mb128_enable(mb128_enable_s),

      .cd_audio_boost(cd_audio_boost_s),
      .adpcm_audio_boost(adpcm_audio_boost_s),
      .master_audio_boost(master_audio_boost_s),

      // Data in
      .ioctl_wr(ioctl_wr),
      .ioctl_addr(ioctl_addr),
      .ioctl_dout(ioctl_dout),
      .cart_download(ioctl_download_s),

      // Data out
      .sd_wr(sd_wr),
      .sd_buff_addr(sd_buff_addr[8:1]),
      .sd_lba(sd_buff_addr[24:9]),
      .sd_buff_dout(sd_buff_dout),
      .sd_buff_din(sd_buff_din),
      .save_download(save_download_s),

      // SDRAM
      .dram_a(dram_a),
      .dram_ba(dram_ba),
      .dram_dq(dram_dq),
      .dram_dqm(dram_dqm),
      .dram_clk(dram_clk),
      .dram_cke(dram_cke),
      .dram_ras_n(dram_ras_n),
      .dram_cas_n(dram_cas_n),
      .dram_we_n(dram_we_n),

      .ce_pix (ce_pix),
      .hblank (h_blank),
      .vblank (v_blank),
      .hsync  (video_hs_core),
      .vsync  (video_vs_core),
      .video_r(vid_rgb_core[23:16]),
      .video_g(vid_rgb_core[15:8]),
      .video_b(vid_rgb_core[7:0]),

      .dotclock_divider(dotclock_divider),
      .border(border),

      .audio_l(audio_l),
      .audio_r(audio_r),

      // PC Engine CD. The drive model is above, on this side, because the
      // transport that feeds it lives here with the bridge.
      .cd_enable      (cd_enable),
      .cd_stat_in     (cd_stat),
      .cd_msg_in      (cd_msg),
      .cd_stat_get    (cd_stat_get),
      .cd_dout_req    (cd_dout_req),
      .cd_data_in     (cd_data),
      .cd_data_wr_in  (cd_data_wr),
      .cd_audio_wr_in (cd_audio_wr),
      .cd_dm_in       (cd_dm),
      .cd_region_in   (cd_region),

      .cd_comm_out     (cd_comm),
      .cd_comm_send_out(cd_comm_send),
      .cd_dout_out     (cd_dout),
      .cd_dout_send_out(cd_dout_send),
      .cd_data_end_out (cd_data_end),
      .cd_reset_out    (cd_reset_lvl)
  );

  ////////////////////////////////////////////////////////////////////////////////////////

  // Video
  wire ce_pix;
  wire h_blank;
  wire v_blank;
  wire video_hs_core;
  wire video_vs_core;
  wire [23:0] vid_rgb_core;

  assign video_rgb_clock = clk_sys_42_95;
  assign video_rgb_clock_90 = clk_vid_42_95_90deg;

  assign video_skip = 0;

  // ---------------------------------------------------------------- overlay
  // The names of the loaded cheats, drawn over the game picture. APF fixes menu
  // labels at build time, so the menu can never name a cheat; the picture can.
  //
  // Clocked at clk_mem_85_91, not clk_sys_42_95. color_mix registers the
  // picture, the blanking and ce_pix in that domain, so an overlay on the
  // slower clock sees only the ce_pix pulses that happen to align with its own
  // edges and its pixel counters never track. cheat_titles is a dual clock RAM
  // for exactly this: the parser writes on clk_sys, the overlay reads here.
  //
  // Injected before the linebuffer, in the core's own pixel space. The panel is
  // 156x144 and the narrowest mode is 256x224, so it fits every mode without
  // the overlay knowing which one is running. Note that the wider raster is
  // still not free: see the text_col width comment in cheat_osd.sv, where a
  // counter sized for the Game Boy wrapped mid-line and drew the panel twice.
  wire       osd_active, osd_ink;
  wire [4:0] osd_title_group, osd_title_col;
  wire [5:0] osd_title_char, osd_font_ch;
  wire [4:0] osd_title_len;
  wire [2:0] osd_font_row;
  wire [7:0] osd_font_bits;

  wire osd_de = ~h_blank & ~v_blank;

  cheat_titles titles (
      .wr_clk  (clk_sys_42_95),
      .wr_reset(cheat_reset),
      .wr_en   (cheat_desc_wr),
      .wr_group(cheat_desc_group),
      .wr_col  (cheat_desc_col),
      .wr_char (cheat_desc_char),
      .wr_end  (cheat_desc_end),
      .rd_clk  (clk_mem_85_91),
      .rd_group(osd_title_group),
      .rd_col  (osd_title_col),
      .rd_char (osd_title_char),
      .rd_len  (osd_title_len)
  );

  cheat_font font (
      .ch  (osd_font_ch),
      .row (osd_font_row),
      .bits(osd_font_bits)
  );

  cheat_osd #(
      .DIAG(CD_PROBE)
  ) osd (
      .clk    (clk_mem_85_91),
      .reset  (~reset_n),
      .show   (show_cheats_v),
      .ce_pix (ce_pix),
      .de     (osd_de),
      .v_blank(v_blank),

      .title_count(cheat_title_count),
      .code_count (cheat_code_total),

      .diag_valid(osd_diag_valid_v),
      .diag_raddr(osd_diag_raddr),
      .diag_rchar(osd_diag_rchar),

      .title_group(osd_title_group),
      .title_col  (osd_title_col),
      .title_char (osd_title_char),
      .title_len  (osd_title_len),

      .font_ch  (osd_font_ch),
      .font_row (osd_font_row),
      .font_bits(osd_font_bits),

      .active(osd_active),
      .ink   (osd_ink)
  );

  // Ink white, panel background black. Drawn over the picture rather than
  // blended, so the text stays readable on any background the game puts up.
  wire [23:0] vid_rgb_osd = osd_active ? (osd_ink ? 24'hFFFFFF : 24'h000000)
                                       : vid_rgb_core;

  linebuffer linebuffer (
      .clk_vid(clk_sys_42_95),

      .vsync_in(video_vs_core),
      .hsync_in(video_hs_core),

      .ce_pix(ce_pix),
      .disable_pix(border),
      .rgb_in(vid_rgb_osd),

      .vsync_out(video_vs),
      .hsync_out(video_hs),

      .de(video_de),
      .rgb_out(video_rgb)
  );

  ///////////////////////////////////////////////

  sound_i2s #(
      .CHANNEL_WIDTH(16),
      .SIGNED_INPUT (1)
  ) sound_i2s (
      .clk_74a  (clk_74a),
      .clk_audio(clk_sys_42_95),

      .audio_l(audio_l),
      .audio_r(audio_r),

      .audio_mclk(audio_mclk),
      .audio_lrck(audio_lrck),
      .audio_dac (audio_dac)
  );

  ///////////////////////////////////////////////


  wire clk_mem_85_91;
  wire clk_sys_42_95;
  wire clk_vid_42_95_90deg;
  // wire clk_vid_10_738;
  // wire clk_vid_10_738_90deg;
  // wire clk_vid_7_159;
  // wire clk_vid_7_159_90deg;

  wire pll_core_locked;

  mf_pllbase mp1 (
      .refclk(clk_74a),
      .rst   (0),

      .outclk_0(clk_mem_85_91),
      .outclk_1(clk_sys_42_95),
      .outclk_2(clk_vid_42_95_90deg),
      // .outclk_2(clk_vid_10_738),
      // .outclk_3(clk_vid_10_738_90deg),
      // .outclk_4(clk_vid_7_159),
      // .outclk_5(clk_vid_7_159_90deg),

      .locked(pll_core_locked)
  );



endmodule
