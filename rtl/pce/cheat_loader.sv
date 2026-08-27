// SPDX-License-Identifier: GPL-3.0-or-later
//
// cheat_loader - parse libretro .cht files into cheat_poker table entries
//
// Consumes the raw bytes of a .cht file from data_loader and writes each
// usable code into cheat_poker's table. Nothing is decoded host-side: drop a
// file from libretro-database/cht next to the ROM and it works.
//
// PC Engine files come in two shapes and a file uses one or the other. Both
// target the same 8KB of work RAM at bank $F8; neither patches ROM.
//
// 246 files use a packed hex string, several codes joined by '+':
//
//     cheat0_desc = "Infinite Energy"
//     cheat0_code = "1f14c5:40"
//     cheat1_code = "1f152f:09+1f1530:09+1f1531:09"
//
// 151 files leave _code empty and give a decimal offset and value instead,
// with the keys in alphabetical order:
//
//     cheat0_address = "6148"
//     cheat0_cheat_type = "1"
//     cheat0_code = ""
//     cheat0_enable = "false"
//     cheat0_value = "10"
//
// Field names are matched over their whole length, never as a prefix or a
// suffix, because that second form is full of near misses:
// `cheat0_rumble_value` ends in `_value`, `cheat0_rumble_type` ends in
// `_type`, and `cheat0_address_bit_position` starts with `address`. A key
// counts here only when it is literally `cheat<digits>_<field>` with `=`
// following and <field> equal to one of the five names below, length included.
// `cheats = "1"` fails at the 's', which is what should happen to it.
//
// Two kinds of row are dropped rather than poked. `cheat_type = 0` marks the
// 70 rows that watch an address to buzz the rumble pack and write nothing.
// Anything outside $1F0000-$1F1FFF is unreachable through the 8KB the CPU sees
// here, which covers the 13 SuperGrafx-sized addresses in the database and the
// 3 impossible ones.
//
// Whether a cheat is on comes from the file, via `cheatN_enable`. APF fixes
// menu labels at build time, so per-cheat menu checkboxes would read "Cheat 1",
// "Cheat 2" and tell the user nothing; the GB/GBC fork built them and then
// removed them again.
//
// Codes commit optimistically as they parse and roll back if the group turns
// out to be disabled or rumble-only. That ordering is forced by the files: in
// the hex form `_enable` follows `_code`, so a code has to be staged before its
// fate is known, while in the decimal form the alphabetical key order puts
// `_enable` and `_cheat_type` before `_value`, so there the fate is known
// first. Committing then rolling back is correct for both, and it means a
// group with no `_enable` key at all stays on, which is what a hand-written
// file listing nothing but codes wants. It also means the count is right after
// every byte rather than only at the end, so no end-of-file signal is needed,
// and data_loader does not provide one.
//

`default_nettype none

module cheat_loader #(
    parameter MAX_CODES = 32,
    parameter INDEX_W   = 5
) (
    input  wire                clk,
    input  wire                reset,   // new file, new ROM, or core reset

    input  wire                wr,      // byte strobe from data_loader
    input  wire [7:0]          data,

    // cheat_poker table load port
    output reg                 code_wr    = 0,
    output reg  [INDEX_W-1:0]  code_index = 0,
    output reg  [12:0]         code_addr  = 0,
    output reg  [7:0]          code_data  = 0,
    output reg  [INDEX_W:0]    code_total = 0,  // committed, live codes

    // Cheat names, streamed to cheat_titles for the overlay. A group's _desc
    // always arrives before that group is finished, so it is written at the
    // slot the group is about to take: if the group turns out to be disabled
    // it never commits, title_count does not advance, and the next name lands
    // in the same slot and overwrites it.
    output reg                 desc_wr    = 0,
    output reg  [4:0]          desc_group = 0,
    output reg  [4:0]          desc_col   = 0,
    output reg  [5:0]          desc_char  = 0,   // ASCII - 32, uppercased
    output reg                 desc_end   = 0,
    output reg  [5:0]          title_count = 0,  // groups that kept their codes

    // menu readout
    output reg  [INDEX_W:0]    group_count = 0,
    output reg  [19:0]         byte_count  = 0
);

  localparam [2:0] F_NONE = 3'd0, F_CODE = 3'd1, F_ADDR = 3'd2,
                   F_VAL  = 3'd3, F_EN   = 3'd4, F_TYPE = 3'd5,
                   F_DESC = 3'd6;

  localparam [3:0] S_SOL    = 4'd0,  // start of line
                   S_PREFIX = 4'd1,  // matching "cheat"
                   S_INDEX  = 4'd2,  // the digits of cheatN
                   S_FIELD  = 4'd3,  // the name after the underscore
                   S_EQ     = 4'd4,  // waiting for '='
                   S_VALUE  = 4'd5,  // reading the value
                   S_SKIP   = 4'd6;  // discard to end of line

  reg [3:0]  state      = S_SOL;
  reg [2:0]  prefix_pos = 0;
  reg [4:0]  field_pos  = 0;
  reg [5:0]  key_ok     = 0;
  reg [2:0]  field      = F_NONE;

  reg [INDEX_W:0] grp       = 0;   // cheatN, N as parsed
  reg [INDEX_W:0] grp_cur   = 0;   // group being assembled
  reg             grp_valid = 0;
  reg [INDEX_W:0] grp_base  = 0;   // where this group's codes start
  reg [INDEX_W:0] stage_ptr = 0;   // next slot this group will use

  reg dec_addr_seen = 0, dec_val_seen = 0;
  // Set when this group is disabled or is a rumble watcher. The hex form is
  // handled by the rollback below, because there _enable follows _code. The
  // decimal form needs this flag instead: its keys are alphabetical, so
  // _enable and _cheat_type both arrive BEFORE _value, and a rollback that has
  // already happened cannot stop a code the value key is about to stage.
  reg g_dead = 0;
  reg [15:0] dec_addr = 0;
  reg [7:0]  dec_val  = 0;

  reg        in_quote = 0;
  reg [23:0] hex_addr = 0;
  reg [7:0]  hex_val  = 0;
  reg        in_val   = 0;   // past the ':' of addr:val
  reg        any_hex  = 0;

  wire is_digit = (data >= "0") && (data <= "9");
  wire is_lower = (data >= "a") && (data <= "z");
  wire is_hex   = is_digit || ((data >= "a") && (data <= "f"))
                           || ((data >= "A") && (data <= "F"));
  wire is_eol   = (data == 8'h0A) || (data == 8'h0D);
  wire is_space = (data == " ") || (data == 8'h09);

  wire [7:0] nib8 = is_digit      ? (data - "0")
                  : (data >= "a") ? (data - "a" + 8'd10)
                                  : (data - "A" + 8'd10);
  wire [3:0] hex_nib = nib8[3:0];

  wire [7:0] desc_fold = (data >= "a" && data <= "z") ? (data - 8'h40)
                                                     : (data - 8'h20);

  // $1F0000-$1F1FFF is the 8KB the CPU reaches here. 0x1F0000 >> 13 = 0xF8.
  wire hex_in_range = (hex_addr[23:13] == 11'h0F8);
  wire dec_in_range = (dec_addr < 16'd8192);

  wire room = (stage_ptr < MAX_CODES[INDEX_W:0]);

  // Whole-length match of the field name just consumed.
  wire [2:0] field_hit =
      (key_ok[0] && field_pos == 4'd4)  ? F_CODE :   // code
      (key_ok[1] && field_pos == 4'd7)  ? F_ADDR :   // address
      (key_ok[2] && field_pos == 4'd5)  ? F_VAL  :   // value
      (key_ok[3] && field_pos == 4'd6)  ? F_EN   :   // enable
      (key_ok[4] && field_pos == 4'd10) ? F_TYPE :   // cheat_type
      (key_ok[5] && field_pos == 4'd4)  ? F_DESC :   // desc
                                          F_NONE;

  // Per-position characters of the five names, as one flat compare.
  function [7:0] kc(input [2:0] k, input [3:0] p);
    reg [87:0] s;
    begin
      case (k)
        3'd0: s = {"code",       56'd0};
        3'd1: s = {"address",    32'd0};
        3'd2: s = {"value",      48'd0};
        3'd3: s = {"enable",     40'd0};
        3'd4: s = {"cheat_type", 8'd0};   // 10 chars, the longest name here
        3'd5: s = {"desc",       56'd0};
        default: s = 88'd0;
      endcase
      kc = s[87 - 8*p -: 8];
    end
  endfunction

  function [3:0] klen(input [2:0] k);
    begin
      case (k)
        3'd0: klen = 4'd4;
        3'd1: klen = 4'd7;
        3'd2: klen = 4'd5;
        3'd3: klen = 4'd6;
        3'd4: klen = 4'd10;
        3'd5: klen = 4'd4;
        default: klen = 4'd0;
      endcase
    end
  endfunction

  integer k;

  always @(posedge clk) begin
    code_wr  <= 1'b0;
    desc_wr  <= 1'b0;
    desc_end <= 1'b0;

    if (reset) begin
      state         <= S_SOL;
      prefix_pos    <= 0;
      field_pos     <= 0;
      key_ok        <= 6'b111111;
      field         <= F_NONE;
      grp           <= 0;
      grp_cur       <= 0;
      grp_valid     <= 1'b0;
      grp_base      <= 0;
      stage_ptr     <= 0;
      dec_addr      <= 0;
      dec_val       <= 0;
      dec_addr_seen <= 1'b0;
      dec_val_seen  <= 1'b0;
      g_dead        <= 1'b0;
      hex_addr      <= 0;
      hex_val       <= 0;
      in_val        <= 1'b0;
      any_hex       <= 1'b0;
      in_quote      <= 1'b0;
      desc_group    <= 0;
      desc_col      <= 0;
      desc_char     <= 0;
      title_count   <= 0;
      code_index    <= 0;
      code_addr     <= 0;
      code_data     <= 0;
      code_total    <= 0;
      group_count   <= 0;
      byte_count    <= 0;
    end else if (wr) begin
      byte_count <= byte_count + 1'b1;

      case (state)
        S_SOL:
        if (is_eol || is_space) state <= S_SOL;
        else if (data == "c") begin
          prefix_pos <= 3'd1;
          state      <= S_PREFIX;
        end else state <= S_SKIP;

        // "cheat" then digits. "cheats = ..." dies here on the 's'.
        S_PREFIX:
        case (prefix_pos)
          3'd1: if (data == "h") prefix_pos <= 3'd2; else state <= S_SKIP;
          3'd2: if (data == "e") prefix_pos <= 3'd3; else state <= S_SKIP;
          3'd3: if (data == "a") prefix_pos <= 3'd4; else state <= S_SKIP;
          3'd4: if (data == "t") begin
                  grp   <= 0;
                  state <= S_INDEX;
                end else state <= S_SKIP;
          default: state <= S_SKIP;
        endcase

        S_INDEX:
        if (is_digit) begin
          grp <= (grp * 6'd10) + {{(INDEX_W-3){1'b0}}, hex_nib};
        end else if (data == "_") begin
          field_pos <= 0;
          key_ok    <= 6'b111111;
          state     <= S_FIELD;

          // A different cheatN starts a new group. The previous one is already
          // committed or already rolled back, so nothing needs flushing.
          if (!grp_valid || grp != grp_cur) begin
            grp_cur       <= grp;
            grp_valid     <= 1'b1;
            grp_base      <= code_total;
            stage_ptr     <= code_total;
            // The group just finished kept codes, so its name keeps its slot
            // and the next name goes to the one after.
            if (grp_valid && code_total > grp_base)
              title_count <= title_count + 6'd1;
            dec_addr      <= 0;
            dec_val       <= 0;
            dec_addr_seen <= 1'b0;
            dec_val_seen  <= 1'b0;
            g_dead        <= 1'b0;
            group_count   <= group_count + 1'b1;
          end
        end else state <= S_SKIP;

        S_FIELD:
        if (is_lower || data == "_") begin
          for (k = 0; k < 6; k = k + 1)
            if (field_pos >= klen(k[2:0]) || data != kc(k[2:0], field_pos))
              key_ok[k] <= 1'b0;
          field_pos <= field_pos + 1'b1;
        end else if (data == "=" || is_space) begin
          field    <= field_hit;
          hex_addr <= 0;
          hex_val  <= 0;
          in_val   <= 1'b0;
          any_hex  <= 1'b0;
          state    <= (data == "=") ? S_VALUE : S_EQ;
        end else state <= S_SKIP;

        S_EQ:
        if (data == "=") state <= S_VALUE;
        else if (!is_space) state <= S_SKIP;

        S_VALUE:
        if (is_eol) begin
          state    <= S_SOL;
          in_quote <= 1'b0;
          // The decimal form's value key is last, so both halves are known
          // here, and so are enable and cheat_type.
          if (field == F_VAL && dec_addr_seen && dec_val_seen
              && !g_dead && dec_in_range && room) begin
            code_wr    <= 1'b1;
            code_index <= stage_ptr[INDEX_W-1:0];
            code_addr  <= dec_addr[12:0];
            code_data  <= dec_val;
            stage_ptr  <= stage_ptr + 1'b1;
            code_total <= stage_ptr + 1'b1;
          end
        end else begin
          case (field)
            F_CODE:
            if (is_hex) begin
              any_hex <= 1'b1;
              if (in_val) hex_val  <= {hex_val[3:0], hex_nib};
              else        hex_addr <= {hex_addr[19:0], hex_nib};
            end else if (data == ":") begin
              in_val <= 1'b1;
            end else if (data == "+" || data == 8'h22) begin
              if (any_hex && in_val && hex_in_range && room) begin
                code_wr    <= 1'b1;
                code_index <= stage_ptr[INDEX_W-1:0];
                code_addr  <= hex_addr[12:0];
                code_data  <= hex_val;
                stage_ptr  <= stage_ptr + 1'b1;
                code_total <= stage_ptr + 1'b1;  // optimistic, see header
              end
              hex_addr <= 0;
              hex_val  <= 0;
              in_val   <= 1'b0;
              any_hex  <= 1'b0;
            end

            // The name, between its quotes, uppercased into font indices.
            F_DESC:
            if (data == 8'h22) begin
              if (in_quote) begin
                in_quote <= 1'b0;
                desc_end <= 1'b1;     // desc_col is now the length
              end else begin
                in_quote <= 1'b1;
                desc_col <= 5'd0;
              end
            end else if (in_quote && desc_col < 5'd26) begin
              desc_wr    <= 1'b1;
              desc_group <= title_count[4:0];
              // ASCII - 32, with a-z folded to A-Z on the way past. The font
              // holds 64 glyphs, so anything above 0x5F wraps into it; that is
              // the truncation, and it is deliberate.
              desc_char  <= desc_fold[5:0];
              desc_col   <= desc_col + 5'd1;
            end

            F_ADDR:
            if (is_digit) begin
              dec_addr      <= (dec_addr * 16'd10) + {12'd0, hex_nib};
              dec_addr_seen <= 1'b1;
            end

            F_VAL:
            if (is_digit) begin
              dec_val      <= (dec_val * 8'd10) + {4'd0, hex_nib};
              dec_val_seen <= 1'b1;
            end

            // "true" / "false"; a false rolls the group's codes back off the
            // end of the table so the next group overwrites them.
            F_EN:
            if (data == "t" || data == "T") begin
              // leave the optimistic commit standing
            end else if (data == "f" || data == "F") begin
              g_dead     <= 1'b1;
              stage_ptr  <= grp_base;
              code_total <= grp_base;
            end

            // 0 is a rumble watcher: it writes nothing.
            F_TYPE:
            if (is_digit && data == "0") begin
              g_dead     <= 1'b1;
              stage_ptr  <= grp_base;
              code_total <= grp_base;
            end

            default: ;
          endcase
        end

        S_SKIP: if (is_eol) state <= S_SOL;

        default: state <= S_SOL;
      endcase
    end
  end

endmodule

`default_nettype wire
