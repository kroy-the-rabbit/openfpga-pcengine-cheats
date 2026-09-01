// SPDX-License-Identifier: GPL-3.0-or-later
//
// Proves the core can open a file the user never picked.
//
// `docs/CD-PLAN.md` P1. The disc arrives as a cue naming one or more bins, and
// the Pocket's file browser only ever hands the core the one file the user
// chose. Three target commands close that gap:
//
//   0x0190  where is slot N's file?      host writes 256 bytes of absolute path
//   0x0192  open this path into slot M   host reads 256 bytes of path + flags
//   0x0180  read from slot M             the bytes land on the bridge
//
// This runs all three back to back without a cue parser in the way, by taking
// the path 0x0190 returns, swapping the extension for `bin`, opening that and
// reading its first sector. For Rondo the bin sits next to the cue under the
// same stem, so `X.cue` becomes `X.bin` and the chain is exercised end to end.
// P2's parser replaces the extension swap with a real filename out of the cue;
// everything under it stays.
//
// The structs live in a block RAM this module exposes on the bridge, because
// the host writes one of them and reads the other. Layout, from BASE:
//
//   0x000   get_dataslot_file_t    256 bytes, host writes the path here
//   0x200   open_dataslot_file_t   256 bytes of path,
//   0x300     + 4 bytes of flags (bit 0 create, bit 1 resize)
//   0x304     + 4 bytes of size
//
// Bytes are big-endian inside a word: core_top ties bridge_endian_little low,
// so byte 0 of a word is bits [31:24]. Getting that backwards produces a path
// that looks like plausible garbage rather than an obvious failure.
//
// Diagnostic, parameterised off in a shipping build.

`default_nettype none

module dataslot_path #(
    parameter [15:0] SRC_SLOT = 16'd100,   // the slot the user picked
    parameter [15:0] DST_SLOT = 16'd101,   // the slot this opens into
    parameter [31:0] BASE     = 32'h6100_0000,
    parameter [31:0] WINDOW   = 32'h6000_0000,  // where the test sector lands
    parameter [31:0] SECTOR   = 32'd2048
) (
    input  wire         clk,             // clk_74a
    input  wire         reset,

    input  wire         start,           // level from the menu, edge detected

    // Bridge. Writes are watched; reads are answered out of the struct RAM.
    input  wire [ 31:0] bridge_addr,
    input  wire         bridge_wr,
    input  wire [ 31:0] bridge_wr_data,
    input  wire         bridge_rd,
    output wire [ 31:0] bridge_rd_data,

    // Generic target command port.
    output reg          cmd_req,
    output reg  [ 15:0] cmd,
    output reg  [ 31:0] cmd_p0,
    output reg  [ 31:0] cmd_p1,
    output reg  [ 31:0] cmd_p2,
    output reg  [ 31:0] cmd_p3,
    input  wire         cmd_ack,
    input  wire         cmd_done,
    input  wire [ 15:0] cmd_result,

    output wire [155:0] line,
    output reg          valid
);

  localparam [15:0] CMD_GET_NAME  = 16'h0190;
  localparam [15:0] CMD_OPEN_FILE = 16'h0192;
  localparam [15:0] CMD_SLOT_READ = 16'h0180;

  // Two separate memories, not one array with two write ports.
  //
  // The first attempt was a single 256 word array written by both the bridge
  // and the state machine inside one always block. Quartus inferred no memory
  // at all and built 8,192 flip-flops: registers went from 11,095 to 19,195,
  // block memory bits did not move, and the fitter asked for 2021 LABs on a
  // device with 1848. Split this way each memory has exactly one writer and
  // one reader, which is the shape that always infers, and the split falls out
  // of the problem anyway: the host only ever writes the get struct and only
  // ever reads the open struct.
  //
  //   get   BASE + 0x000, 64 words   host writes, this module reads
  //   open  BASE + 0x200, 66 words   this module writes, host reads
  localparam FLAGS_W = 7'd64;   // open struct offset 0x100
  localparam SIZE_W  = 7'd65;   // open struct offset 0x104

  wire a_hit = (bridge_addr[31:24] == BASE[31:24]);

  // ---- get struct ----
  reg [31:0] get_mem[0:63];
  reg [31:0] get_q;
  reg [ 5:0] get_raddr;
  wire       get_we = bridge_wr && a_hit && (bridge_addr[9:8] == 2'b00);

  always @(posedge clk) begin
    if (get_we) get_mem[bridge_addr[7:2]] <= bridge_wr_data;
    get_q <= get_mem[get_raddr];
  end

  // ---- open struct ----
  // Byte 0x200 puts the struct at word 128, so bridge_addr[8:2] indexes it
  // directly. Only the open struct answers bridge reads: the host writes the
  // get struct and never reads it back, so giving that region a read port
  // would be logic for a case that does not occur.
  reg [31:0] open_mem[0:127];
  reg [31:0] open_q;
  reg [ 6:0] open_raddr;
  reg [31:0] open_rd;
  reg [ 6:0] open_waddr;
  reg [31:0] open_din;
  reg        open_we;

  // Registered address in, registered data out, which is the shape
  // core_bridge_cmd uses for its own data table. The first version presented
  // the RAM output straight into core_top's read mux one cycle after the
  // address changed, which only answers correctly if the bridge holds an
  // address for at least a cycle before asserting bridge_rd. Matching the
  // pattern that is already proven on this bus costs two registers and removes
  // the question.
  always @(posedge clk) begin
    open_raddr <= bridge_addr[8:2];
    if (open_we) open_mem[open_waddr] <= open_din;
    open_q <= open_mem[open_raddr];
    if (bridge_rd) open_rd <= open_q;
  end

  assign bridge_rd_data = open_rd;

  // ------------------------------------------------------------- scan ------
  localparam [3:0] ST_IDLE       = 4'd0;
  localparam [3:0] ST_GET        = 4'd1;
  localparam [3:0] ST_GET_WAIT   = 4'd2;
  localparam [3:0] ST_SCAN_FETCH = 4'd3;
  localparam [3:0] ST_SCAN_WAIT  = 4'd4;
  localparam [3:0] ST_SCAN_BYTE  = 4'd5;
  localparam [3:0] ST_BUILD      = 4'd6;
  localparam [3:0] ST_BUILD_WAIT = 4'd7;
  localparam [3:0] ST_BUILD_WR   = 4'd8;
  localparam [3:0] ST_FLAGS      = 4'd9;
  localparam [3:0] ST_OPEN       = 4'd10;
  localparam [3:0] ST_OPEN_WAIT  = 4'd11;
  localparam [3:0] ST_READ       = 4'd12;
  localparam [3:0] ST_READ_WAIT  = 4'd13;
  localparam [3:0] ST_DONE       = 4'd14;

  reg [ 3:0] state = ST_IDLE;
  reg        start_d = 0;
  wire       start_rise = start & ~start_d;

  reg [ 8:0] idx;                 // byte index while scanning
  reg [ 8:0] dot;                 // last '.' seen, 511 if none
  reg [ 8:0] len;                 // index of the terminating NUL
  reg [ 6:0] wcnt;                // word counter while building

  reg [ 3:0] get_res, open_res, read_res;
  reg [31:0] first_word;
  reg [31:0] built;               // the rebuilt path word past the dot
  reg        got_first;

  // {1'b0, wcnt[5:0], 2'd0} is wcnt*4 in exactly the 9 bits the byte index is
  // carried in. Built by concatenation rather than a shift so the width is
  // stated rather than inferred and then truncated.
  wire [31:0] built_val = {
    out_byte(get_q[31:24], {1'b0, wcnt[5:0], 2'd0} | 9'd0, dot),
    out_byte(get_q[23:16], {1'b0, wcnt[5:0], 2'd0} | 9'd1, dot),
    out_byte(get_q[15:8],  {1'b0, wcnt[5:0], 2'd0} | 9'd2, dot),
    out_byte(get_q[7:0],   {1'b0, wcnt[5:0], 2'd0} | 9'd3, dot)
  };

  // The byte of a struct word that byte index i names, big-endian inside it.
  function automatic [7:0] lane(input [31:0] w, input [1:0] i);
    begin
      case (i)
        2'd0: lane = w[31:24];
        2'd1: lane = w[23:16];
        2'd2: lane = w[15:8];
        default: lane = w[7:0];
      endcase
    end
  endfunction

  // What byte index i of the rebuilt path should be: the original up to and
  // including the last dot, then "bin", then NUL padding. With no dot in the
  // path at all the original is copied untouched and 0x0192 is left to say
  // what it thinks of that.
  function automatic [7:0] out_byte(input [7:0] orig, input [8:0] i,
                                    input [8:0] d);
    reg [8:0] k;
    begin
      if (d == 9'd511 || i <= d) out_byte = orig;
      else begin
        k = i - d - 9'd1;
        case (k)
          9'd0: out_byte = "b";
          9'd1: out_byte = "i";
          9'd2: out_byte = "n";
          default: out_byte = 8'd0;
        endcase
      end
    end
  endfunction

  always @(posedge clk) begin
    start_d <= start;

    if (reset) begin
      state   <= ST_IDLE;
      cmd_req <= 1'b0;
      open_we <= 1'b0;
      valid   <= 1'b0;
    end else begin
      open_we <= 1'b0;

      // The first word of the test sector, latched where it lands.
      if (state == ST_READ_WAIT && bridge_wr && !got_first &&
          bridge_addr[31:24] == WINDOW[31:24]) begin
        first_word <= bridge_wr_data;
        got_first  <= 1'b1;
      end

      case (state)
        ST_IDLE: begin
          cmd_req <= 1'b0;
          if (start_rise) begin
            valid     <= 1'b0;
            get_res   <= 4'd15;
            open_res  <= 4'd15;
            read_res  <= 4'd15;
            first_word <= 32'd0;
            built     <= 32'd0;
            got_first <= 1'b0;
            dot       <= 9'd511;
            len       <= 9'd0;
            idx       <= 9'd0;
            state     <= ST_GET;
          end
        end

        // ---- 0x0190, where is the user's file ----
        ST_GET: begin
          cmd    <= CMD_GET_NAME;
          cmd_p0 <= {16'd0, SRC_SLOT};
          cmd_p1 <= BASE;
          cmd_p2 <= 32'd0;
          cmd_p3 <= 32'd0;
          cmd_req <= 1'b1;
          state  <= ST_GET_WAIT;
        end
        ST_GET_WAIT: begin
          if (cmd_ack) cmd_req <= 1'b0;
          if (cmd_done) begin
            get_res <= cmd_result[3:0];
            if (cmd_result != 16'd0) state <= ST_DONE;
            else                     state <= ST_SCAN_FETCH;
          end
        end

        // ---- find the last dot and the terminator ----
        ST_SCAN_FETCH: begin
          get_raddr <= idx[7:2];
          state     <= ST_SCAN_WAIT;
        end
        ST_SCAN_WAIT: state <= ST_SCAN_BYTE;
        ST_SCAN_BYTE: begin
          if (lane(get_q, idx[1:0]) == 8'd0) begin
            len   <= idx;
            wcnt  <= 7'd0;
            state <= ST_BUILD;
          end else begin
            if (lane(get_q, idx[1:0]) == ".") dot <= idx;
            idx <= idx + 9'd1;
            // A new word is needed once the index rolls past this one, and the
            // scan must not run off the end of a 256 byte struct.
            if (idx == 9'd255) begin
              len   <= 9'd255;
              wcnt  <= 7'd0;
              state <= ST_BUILD;
            end else if (idx[1:0] == 2'd3) begin
              state <= ST_SCAN_FETCH;
            end
          end
        end

        // ---- copy the path with the extension replaced ----
        ST_BUILD: begin
          get_raddr <= wcnt[5:0];
          state     <= ST_BUILD_WAIT;
        end
        ST_BUILD_WAIT: state <= ST_BUILD_WR;
        ST_BUILD_WR: begin
          open_waddr <= {1'b0, wcnt[5:0]};
          open_din <= built_val;
          open_we  <= 1'b1;
          // Keep the word just past the dot, which is where the extension swap
          // lands. It is the difference between "the path I built is wrong"
          // and "the path I built is right and the host read something else",
          // and those two have looked identical for two builds running.
          if (wcnt == (dot[8:2] + 7'd1)) built <= built_val;
          if (wcnt == 7'd63) state <= ST_FLAGS;
          else begin
            wcnt  <= wcnt + 7'd1;
            state <= ST_BUILD;
          end
        end

        // ---- flags and size both zero: open an existing file, do not create ----
        ST_FLAGS: begin
          open_waddr <= FLAGS_W;
          open_din   <= 32'd0;
          open_we    <= 1'b1;
          wcnt       <= 7'd0;
          state      <= ST_OPEN;
        end

        // ---- 0x0192, open it ----
        ST_OPEN: begin
          // One extra pass to land the size word, then issue.
          if (wcnt == 7'd0) begin
            open_waddr <= SIZE_W;
            open_din   <= 32'd0;
            open_we    <= 1'b1;
            wcnt       <= 7'd1;
          end else begin
            cmd     <= CMD_OPEN_FILE;
            cmd_p0  <= {16'd0, DST_SLOT};
            cmd_p1  <= BASE + 32'h200;
            cmd_p2  <= 32'd0;
            cmd_p3  <= 32'd0;
            cmd_req <= 1'b1;
            state   <= ST_OPEN_WAIT;
          end
        end
        ST_OPEN_WAIT: begin
          if (cmd_ack) cmd_req <= 1'b0;
          if (cmd_done) begin
            open_res <= cmd_result[3:0];
            // 0 is opened, 1 is created and opened. Anything else is a failure
            // worth stopping on rather than reading a slot that holds nothing.
            if (cmd_result > 16'd1) state <= ST_DONE;
            else                    state <= ST_READ;
          end
        end

        // ---- 0x0180, prove something can be read out of it ----
        ST_READ: begin
          cmd     <= CMD_SLOT_READ;
          cmd_p0  <= {16'd0, DST_SLOT};
          cmd_p1  <= 32'd0;
          cmd_p2  <= WINDOW;
          cmd_p3  <= SECTOR;
          cmd_req <= 1'b1;
          state   <= ST_READ_WAIT;
        end
        ST_READ_WAIT: begin
          if (cmd_ack) cmd_req <= 1'b0;
          if (cmd_done) begin
            read_res <= cmd_result[3:0];
            state    <= ST_DONE;
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
  // "G0 O0 R0 L064 xxxxxxxx": the three result codes, the path length the scan
  // found, and the first word that came back. A plausible length says 0x0190
  // returned a real path rather than an empty buffer, which is the failure
  // that would otherwise look identical to a bad filename.
  localparam [5:0] SP = 6'd0, G = 6'd39, L = 6'd44, O = 6'd47, P = 6'd48,
                   R = 6'd50;

  function automatic [5:0] hex(input [3:0] v);
    begin
      hex = (v < 4'd10) ? (6'h10 + {2'd0, v}) : (6'd33 + {2'd0, v} - 6'd10);
    end
  endfunction

  assign line = {
      G, hex(get_res), SP,
      O, hex(open_res), SP,
      R, hex(read_res), SP,
      L, hex({3'd0, len[8]}), hex(len[7:4]), hex(len[3:0]), SP,
      P, hex(built[31:28]), hex(built[27:24]),
      hex(built[23:20]), hex(built[19:16]),
      hex(built[15:12]), hex(built[11:8]),
      hex(built[7:4]), hex(built[3:0]),
      SP, SP, SP
  };

endmodule

`default_nettype wire
