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
      .audio_r(audio_r)
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

  cheat_osd osd (
      .clk    (clk_mem_85_91),
      .reset  (~reset_n),
      .show   (show_cheats_v),
      .ce_pix (ce_pix),
      .de     (osd_de),
      .v_blank(v_blank),

      .title_count(cheat_title_count),
      .code_count (cheat_code_total),

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
