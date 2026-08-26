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

## P1: what is built, and how to test it

P1 proves the mechanism with no file I/O. The load port
(`code_wr`/`code_index`/`code_addr`/`code_data`/`code_live`) is tied idle, and
with `SEED_EN` set the live code comes from the `Test Cheat` menu selector
instead of the table.

Because nothing writes the table in this build, it costs nothing here. The
first version, which seeded the table from parameters at reset, did instantiate
it: Quartus inferred an altsyncram and then trimmed it to two entries of the
thirty-two, reporting `Removed 4 MSB VCC or GND address nodes`, and it occupied
one M10K. Once the selector replaced the seed the table lost its only writer
and went away entirely, which is the M10K that came back. What P1 measures is
therefore the state machine, the vblank edge detect and the port B arbitration.
The table's real cost arrives in P2, when the loader gives it a reason to be
thirty-two deep.

### Verified on hardware, 2026-08-26

Both halves confirmed on a real Pocket:

* **DEBUG Wipe Work RAM** sweeps all 8KB with zeroes through the port B path.
  Turning it on kills the running game instantly. That proves the bridge write
  reaches the core, crosses into `clk_sys_42_95`, gets past the port B mux and
  lands in work RAM.
* **R-Type "Auto Fire (Charged Shot)"**, `1f016f:80`, applied through the full
  poker path: FSM, vblank edge, code lookup and all. The ship fires charged
  shots by itself the moment the switch goes on.

### How to pick a test cheat, and how not to

The first hardware test of this failed, and the mechanism was not the reason.
The seed was Bonk's Adventure "Infinite Lives", `1f0db1:02`, chosen because a
life counter seemed easy to read. It is not:

* Nothing repaints the HUD until the count changes, so the poke can be landing
  every frame with nothing on screen to show it.
* Observing it needs a death, which makes a "did it work" test into a "play the
  game for a minute" test.

**Choose a cheat whose value gameplay code reads every frame**, not one that
feeds a cached HUD number. Auto fire, weapon level and health gauges all show
up in the same frame the switch flips. Lives, credits and score counters do
not.

The wipe is what separated the two possibilities, and it is worth keeping for
exactly that reason. It bypasses the vblank edge, the code table and the FSM,
so if the wipe works and a cheat does not, the fault is in the cheat or in the
poker's logic, never in the write path. If neither works, the fault is in the
bridge or the mux. One toggle splits the search space in half.

### The test menu

Two diagnostic entries exist in `interact.json` alongside the real switch. Both
are development aids and **P6 should strip them from the shipped menu**, though
the RTL can stay: it is parameterised off (`DEBUG_WIPE = 0`, `SEED_EN = 0`) and
costs nothing when disabled.

| Entry | Address | Purpose |
|---|---|---|
| Cheats Enabled | `0x404` | The real master switch. |
| DEBUG Wipe Work RAM | `0x408` | Write-path diagnostic, destroys the running game. |
| Test Cheat | `0x40C` | Dropdown of known-good codes, selected at runtime. |

`Test Cheat` exists because the first version compiled its cheat in as a
parameter, so trying another address cost a 15 minute rebuild. With `SEED_EN`
set the poker takes its live code from this selector and bypasses the table
entirely; the table and load port underneath are untouched and waiting for P2.

Both gates must be open for a poke: `Cheats Enabled` ticked **and** `Test Cheat`
set to something other than Off.

## Wiring

| Piece | Where |
|---|---|
| `cheat_poker` instance | `rtl/main.sv`, after the `pce_top` instance |
| `POKE_A` / `POKE_D` / `POKE_WE` | `pce_top.vhd` entity, next to `BRM_*` |
| Port B mux | `pce_top.vhd`, under the `RAM` instance |
| `cheats_enabled` bridge write | `target/pocket/core_top.v`, `32'h404` |
| Clock-domain crossing | `settings_s` synchroniser, widened to 15 |
| Menu entry | `interact.json`, id 81, address `0x00000404` |

`0x400` is the `Swap ROM Bit Order` toggle; the cheat addresses start at
`0x404`. Note this core decodes small bridge addresses directly and does **not**
use the `0xF0000000` scheme the GB/GBC core does.
