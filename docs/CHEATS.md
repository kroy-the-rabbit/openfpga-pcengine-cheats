# Cheats on the Pocket PC Engine core

## What a PC Engine cheat is

A RAM poke, and only a RAM poke.

All 397 published `.cht` files in libretro's `NEC - PC Engine - TurboGrafx 16`
database were parsed and every one of their 1224 codes read. None patches ROM.
1208 land inside `0x1F0000`-`0x1F1FFF`, which is the 8KB of work RAM at bank
`$F8`. The remainder are either outside what this core maps or not addresses
this machine has. There is no Game Genie for the PC Engine in that database.

That is why the cheat path here is `cheat_poker.sv` and not the `CODES`
read-override comparator. `CODES` is still present in `pce_top.vhd`, still
gated in by `generate_CHEAT`, and still costs **0 ALMs**, because nothing drives
`gg_code` and Quartus folds the whole comparator away. It stays that way: free
where it sits, and available if a ROM-patch code ever turns up.

## How the poke reaches memory

Work RAM is a `dpram` (`pce_top.vhd`). Port A is the CPU's. Port B belonged
solely to the cold-reset clear, a free-running counter that zeroes the block at
load, and that is the port the poker borrows:

    RAM_B_A  <= CLR_A when CLR_WE = '1' else "00" & POKE_A;
    RAM_B_D  <= (others => '0') when CLR_WE = '1' else POKE_D;
    RAM_B_WE <= CLR_WE or POKE_WE;

The clear always wins. It runs once per load, the poker runs once per frame,
and a poke the clear swallows is simply reissued at the next vblank, so the
arbitration needs no stalling and no handshake. `cheat_poker` also takes
`blocked` (tied to `COLD_RESET`) and abandons its walk rather than waiting.

Only 13 address bits cross the boundary. That is the 8KB the CPU can reach
here, and keeping the upper 24KB of the 32KB block write-only and unread is
what lets Quartus infer 8 M10Ks for it rather than 32 when `SGX_EN = 0`.

## The scan

`cheat_poker` holds its codes in a small `{live, addr[12:0], data[7:0]}` memory
rather than a register file, so a fresh index costs one cycle before the entry
is readable. That is the `SETTLE` state. It also keeps the per-code lookup off
any data path, which is the half of the GB/GBC timing lesson in `PLAN.md` §5
that still applies here now that the read override is cut.

`code_count` is the authority on how far a scan runs, so loading a new file
needs no clearing walk over the table.

There is no bank qualifier. The GB version needs one because `$D000-$DFFF` is
switchable and a code may name an SVBK bank; the PC Engine's 8KB at `$F8` is
not banked.

## Loading a cheat file

Data slot 2, `parameters 0x205`, extensions `cht` and `txt`, streaming to
`0x50000000` one byte at a time. Same shape as the GB/GBC core's slot. Put the
`.cht` beside the ROM and pick it in the menu.

### The chip32 trap, which cost a day

Declaring the slot is not enough on this core, and copying the declaration from
the GB/GBC fork is actively misleading.

Upstream shipped a **chip32 VM program** (`support/chip32.asm`) and it *is* the
core's loader. It reads:

    loadf slot 0   // ROM
    loadf slot 1   // save
    host_init      // start the core
    exit 0

**With a chip32 program present, APF loads only the slots the program names.**
Slot 2 is never requested, so the cheat file never reaches the core at all: the
data_loader sees no bytes, the parser never runs, and every symptom points at
the RTL rather than at the manifest.

The GB/GBC fork ships **no** chip32 program, so APF loads every declared slot
by itself. That is the only reason the same slot declaration works there.

So the program is gone from this core, and `ioctl_download`, `save_download`
and `cheat_download` come from the dataslot handshake the way they do in the
GB/GBC fork:

    if (dataslot_requestwrite) any_download <= 1;
    else if (dataslot_allcomplete) any_download <= 0;

    wire ioctl_download = any_download && dataslot_requestwrite_id == 16'd0;

Nothing was lost. The program's only other job was reading the ROM extension to
set `is_sgx`, which is dead while `SGX_EN` is 0 because `main.sv` ands it away.
`support/chip32.asm` is kept for reference with a header saying it is no longer
built; there is no `bass` assembler or `chip32.vm` in the repo, so adding a
third `loadf` to it was never an option anyway.

`cheat_loader.sv` parses the ASCII as it arrives and writes usable codes
straight into `cheat_poker`'s table. Nothing is decoded host-side. The parser
restarts whenever a new cheat file or a new ROM begins loading, and at core
reset, so codes never outlive the game they belong to.

### Two file shapes, and the two traps in them

246 files use a packed hex string, several codes joined by `+`:

    cheat0_code = "1f14c5:40"
    cheat1_code = "1f152f:09+1f1530:09+1f1531:09"

151 leave `_code` empty and give a decimal offset and value, keys in
alphabetical order:

    cheat0_address = "6148"
    cheat0_cheat_type = "1"
    cheat0_code = ""
    cheat0_enable = "false"
    cheat0_value = "10"

**Field names are matched over their whole length**, never as a prefix or a
suffix. That second form is full of near misses: `cheat0_rumble_value` ends in
`_value`, `cheat0_rumble_type` ends in `_type`, `cheat0_address_bit_position`
starts with `address`. Matching loosely reads the wrong number and looks like
it worked. A key counts only as `cheat<digits>_<field>` with `=` following and
the field equal over its full length. `cheats = "1"` fails at the `s`, which is
what should happen to it.

**Codes commit optimistically and roll back.** The two forms disagree on key
order: the hex form puts `_enable` after `_code`, so a code has to be staged
before its fate is known, while the alphabetical form puts `_enable` and
`_cheat_type` before `_value`, so there the fate is known first. Committing and
then rolling back on `false` or on `cheat_type = 0` is correct for both. It also
keeps the count right after every byte rather than only at the end, which
matters because `data_loader` provides no end-of-file signal to flush on.

A group with no `_enable` key at all stays on, so a hand-written file listing
nothing but codes works.

### What gets dropped

| Rows | Why |
|---|---|
| `cheat_type = 0` | 70 rows that watch an address to buzz the rumble pack and write nothing. |
| Outside `$1F0000`-`$1F1FFF` | Not reachable through the 8KB the CPU sees here. Covers the 13 SuperGrafx-sized addresses in the database and the 3 impossible ones. |
| Past 32 codes | `MAX_CODES`. |

### Enable state comes from the file

Via `cheatN_enable`, not from menu checkboxes. APF fixes menu labels at build
time, so generic per-cheat entries could only ever read "Cheat 1", "Cheat 2".
The GB/GBC fork built them and then removed them again; this one does not repeat
that.

`code_total` is the loader's committed count and the only liveness test in the
poker. A disabled cheat is staged into the table and never counted, so the next
group overwrites it. That is why table entries carry no enable bit and why
loading a new file needs no clearing walk.

## The menu

Matches the deployed GB/GBC core, in content and in order.

| Entry | Address | |
|---|---|---|
| Reset core | `0x050` | |
| Cheats enabled | `0x404` | Off by default |
| Show cheats | `0x408` | Off by default |
| DEBUG SD Read Probe | `0x40C` | CD work, stripped before release |
| DEBUG Probe Chunk | `0x410` | CD work, stripped before release |
| DEBUG Path Probe | `0x414` | CD work, stripped before release |
| ...core options... | | |

The menu lists variables in **array order**, not by id, so the two cheat
entries are moved to the top of `interact.json` rather than renumbered. They
were eleventh and twelfth, which meant scrolling past every core option to
reach them.

`persist` is **false** on both, matching GB/GBC. With `persist: true` the Pocket
restores whatever was set last, so a box ticked once during testing comes back
ticked on the next build and the core looks like it defaults cheats on.

`Show cheats` draws the list. `cheat_osd`, `cheat_font` and `cheat_titles` are
ported and wired in `core_top.v`. The §6 problem they were blocked on, that the
overlay was parameterised for a fixed 160x144 Game Boy raster while the PC
Engine has no fixed resolution, is resolved: the panel is clocked at
`clk_mem_85_91`, where `color_mix` registers the picture, and it is inset from
the corner by `COL0` and `ROW0` cells rather than drawn from pixel 0. The inset
is what makes it correct on hardware. Drawn from the corner the first cells sat
in overscan, and the header lost its count digits and every title its first
letter. The inset is applied by leaving those cells empty rather than by
offsetting `py` and gating on `px`, because doing the arithmetic on the
pixel-rate path cost 1,552 ALMs for a cosmetic margin.

## Verified on hardware

2026-08-26, on a real Pocket. A poke applied through the full path: FSM, vblank
edge, code lookup, port B arbitration.

The first hardware attempt failed and the mechanism was not the reason. The
test cheat was a life counter, and nothing repaints a HUD until the count
changes, so a poke landing every frame had nothing to show for itself.

**Choose a cheat whose value gameplay code reads every frame** when testing.
Auto fire, weapon level and health gauges show up in the same frame the switch
flips. Lives, credits and score counters do not.

What isolated it was a diagnostic that bypassed the vblank edge, the table and
the FSM entirely and just swept work RAM through the same port B path. One
toggle separated "no write reaches memory" from "this cheat is wrong". That
scaffolding has since been removed; the technique is worth remembering.

## Wiring

| Piece | Where |
|---|---|
| `cheat_poker` instance | `rtl/main.sv`, after the `pce_top` instance |
| `POKE_A` / `POKE_D` / `POKE_WE` | `pce_top.vhd` entity, next to `BRM_*` |
| Port B mux | `pce_top.vhd`, under the `RAM` instance |
| `cheat_loader` instance | `target/pocket/core_top.v`, before `data_unloader` |
| Cheats byte stream | third `data_loader`, `ADDRESS_MASK_UPPER_4 = 4'h5`, `OUTPUT_WORD_SIZE = 1` |
| Cheats data slot | `data.json`, id 2, `0x50000000` |
| Parser reset | `cheat_reset`, on new cheat file, new ROM, or core reset |
| Poker held off during load | `cheat_busy`, OR'd into `blocked` |
| Bridge writes | `core_top.v`, `32'h404` and `32'h408` |
| Clock-domain crossing | `settings_s` synchroniser, WIDTH 16 |
| Menu entries | `interact.json`, ids 81 and 82; the CD diagnostics are 83 to 85 |

`0x400` is the `Swap ROM Bit Order` toggle; the cheat addresses start at
`0x404`, and the CD work continues to `0x414`. Note this core decodes small bridge addresses directly and does **not**
use the `0xF0000000` scheme the GB/GBC core does.
