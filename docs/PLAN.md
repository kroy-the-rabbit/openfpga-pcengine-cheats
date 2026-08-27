# Plan: SD-card cheat support for the Pocket PC Engine core

Scope: cheats for ROMs loaded from the SD card. Physical HuCards through
Analogue's TurboGrafx-16 adapter are explicitly **out of scope** (§7). An
on-screen cheat list is a **nice to have**, not a requirement (§6).

The sibling project `~/Desktop/repos/pocket-gbc` has already shipped this
feature end to end, overlay included, and its `docs/PLAN.md` records what went
wrong on the way. Most of this plan is "port that, adjusted for the PCE", and
the sections below try to be specific about which parts do not carry over.

---

## 0. Fork decision: `vanfanel/openfpga-pcengine`

Base the work on `vanfanel/master`, keeping `agg23/master` as a second
upstream.

| Candidate | Position vs agg23 | Last commit | Verdict |
|---|---|---|---|
| `agg23/openfpga-pcengine` | canonical | 2024-12-06 | 20 months stale, 9 open issues |
| **`vanfanel/openfpga-pcengine`** | **19 ahead, 0 behind** | **2026-07-09** | **chosen** |
| `Mazamars312/openfpga-pcengine-cd` | separate lineage, not a fork | 2024-09-12 | 0.2.3-BETA, CD focus, adds logic |
| `RndMnkIII/Analogizer_openfpga-pcengine` | 16 ahead, 17 behind | 2025-01-02 | diverged, Analogizer-specific |

Why vanfanel:

* Strictly ahead. 19 commits, nothing behind, so nothing is given up.
* Same author agg23 already merged three PRs from (#29, #30, #31, which are the
  last commits on agg23's master). Their PR #32 has been open since 2025-03-05.
* Tracks `MiSTer-devel/TurboGrafx16_MiSTer`, whose latest commit is the same day
  as vanfanel's last push. agg23's port stopped following it 20 months ago.
* The live delta is small. Of 7 changed files, `cd.vhd`, `SCSI.vhd` and
  `xe1ap.v` are never synthesised into the Pocket build (verified: zero matching
  entities in the fitter report), and the `main.sv` delta is entirely inside
  commented-out CD blocks. What actually changes is `huc6270.vhd`,
  `huc6260.vhd` and `pce_top.vhd`: the VDC and VCE accuracy fixes.

**Confirmed by measurement.** `make compare A=pce B=vanfanel`, same Quartus,
same settings, same machine:

|  | agg23 | vanfanel | delta |
| --- | ---: | ---: | ---: |
| ALMs | 14,779 (80.0%) | 14,700 (79.5%) | **-79** |
| Registers | 14,735 | 14,720 | -15 |
| M10K blocks | 225 (73.1%) | 225 (73.1%) | 0 |
| Worst slack (hold) | +0.103 ns | +0.118 ns | **+0.015 ns** |
| Setup slack | +2.208 ns | +2.253 ns | +0.045 ns |

Strictly better on every axis: 20 months of accuracy fixes for slightly
negative ALM cost and slightly more margin. The cherry-pick fallback this
section used to describe is not needed. The one caveat is that vanfanel's fit
took 44 minutes against the baseline's 19; repeated runs would say whether that
is the design or just machine load, and it does not affect the result.

Both upstreams have their push URL set to DISABLED, so work here cannot land
in someone else's repo by accident. `origin` is the fork. Branches:

    master          the working line: vanfanel + harness + SGX removal + cheats
    agg23-upstream  agg23 master, untouched, for diffing against
    agg23-base      agg23 + harness, holds the baseline measurement
    vanfanel-base   vanfanel + harness, the control build

The working line was called `cheats` until the fork was published. It is
`master` now because that is the branch a release is cut from, and
.github/workflows/release.yml refuses to publish a tag that is not on it.
---

## 1. What this core already has

The PC Engine core is a **much better starting point than the GB/GBC one was**.
There, the cheat engine had been deleted outright and had to be recovered from
git history. Here it was never removed, only disconnected.

| Piece | State |
|---|---|
| `rtl/pce/cheatcodes.sv` | present, Kitrinx's `CODES`, unmodified |
| `GAMEGENIE` instance | `pce_top.vhd:247`, `ADDR_WIDTH => 21, DATA_WIDTH => 8` |
| CPU read override | `GENIE_DI <= GENIE_DO when GENIE else CPU_DI` |
| `gg_*` ports out to `main.sv` | wired, `main.sv:185-188` |
| `gg_code` register | declared, `main.sv:546` |
| The loader that fills it | **commented out, `main.sv:556-568`** |

It costs **0 ALMs today** and does not appear in the fitter report at all,
because `status = 0` (`main.sv:122`), `code_download = 0` (`main.sv:124`) and
nothing ever assigns `gg_code`, so Quartus constant-folds the whole comparator
away. The engine is gated on `generate_CHEAT: if (LITE = 0)`, which is the
default, so it is already "in" the build in name.

Consequence: reconnecting it would be uncommenting rather than re-porting. §4
explains why that turned out not to be worth doing: nothing in the PC Engine
cheat corpus patches ROM, so the engine stays unwired and free, and the work
goes into the poker instead.

---

## 2. Resource budget

Measured on the stock agg23 build (`docs/BASELINE.md`), Quartus 25.1std:

| | ALMs | M10K |
|---|---:|---:|
| Stock core | 14,779 / 18,480 (80.0%) | 225 / 308 (73.1%) |
| After SGX removal (projected) | ~9,338 (~50.5%) | ~157 (~51.0%) |
| GB/GBC cheat stack, measured there | +1,655 | (drove that core to 91% M10K) |
| Projected with cheats | **~11,000 (~59%)** | **~180-200 (~60%)** |

The SGX removal (`SGX_EN = 0`, commit `85f58ba`) is what makes this comfortable.
It frees 5,441 ALMs and 68 M10Ks: `HUC6270:VDC1` at 5,368 ALMs, its 32K VRAM at
64 M10Ks, and the `huc6202` VPC at 49 ALMs.

**Follow-on saving, not yet taken.** `pce_top.vhd:625` declares work RAM as
`dpram generic map (15,8)`, 32KB, because SuperGrafx needs it. With `SGX = '0'`,
`RAM_A(14 downto 13)` is hardwired to `"00"` (`pce_top.vhd:639`), so only 8KB is
reachable and 24 of its 32 M10Ks are dead. Narrowing it to `(13,8)` when
`SGX_EN = 0` frees those. Worth doing if block RAM gets tight during P4, which
is exactly what happened on GBC.

---

## 3. The port, module by module

All six files come from `~/Desktop/repos/pocket-gbc/src/gb/`.

| Module | Lines | Carries over? |
|---|---:|---|
| `cheatcodes.sv` | 261 | **already here.** Needs the §5 timing fix. |
| `cheat_loader.sv` | 379 | near-verbatim; ASCII `.cht` parser, format-agnostic |
| `cheat_poker.sv` | 140 | retarget from GB WRAM/HRAM to PCE work RAM |
| `cheat_osd.sv` | 300 | **hardest port**, see §6 |
| `cheat_font.sv` | 595 | verbatim, glyph ROM |
| `cheat_titles.sv` | 71 | verbatim, description storage |

### Hook points in this repo

* **Cheat file delivery.** `data.json` declares only slot 0 (Cartridge,
  `.pce`/`.sgx`) and slot 1 (Save). Add a Cheats slot, mirroring GBC's:
  `parameters "0x205"`, extensions `["cht","txt"]`, `size_maximum 0x100000`.
  Pick a bridge address that does not collide; GBC learned this the hard way and
  ended up at `0x50000000`.
* **Byte stream.** `core_top.v:541` and `:562` already instantiate `data_loader`
  producing `ioctl_wr / ioctl_addr / ioctl_dout`. Add a third for cheats.
* **Bridge settings.** `core_top.v:332` is a `casex` over small addresses:
  `0x0, 0x4, 0x8, 0x50, 0x100-0x10C, 0x200-0x208, 0x300-0x308`. **`0x400+` is
  free.** Note this core does *not* use the `0xF0000000` scheme the GBC core
  does, so GBC's addresses do not transfer.
* **Menu.** `interact.json` holds **10 variables and APF allows 16**, so 6 are
  free. An earlier draft said 12 and 4; that counted the nested option labels
  inside the audio dropdowns, which are not menu entries. GBC needs 2 ("Cheats
  enabled", "Show cheats"), and "Swap ROM Bit Order" now takes a third. Fits,
  with room for a parsed-count readout.
* **RAM poking.** `pce_top.vhd:625`, work RAM is a `dpram` whose **port B is used
  only by the cold-reset clear** (`CLR_A` / `CLR_WE`). That is the same shape as
  the GB WRAM port B the poker already borrows, so the technique transfers
  directly. Arbitrate against `COLD_RESET` instead of GBC's `savestate_busy`.
* **Video, for the overlay.** `core_top.v:839` `vid_rgb_core` comes out of the
  linebuffer (`:818-822`) and goes into the scaler (`:849-856`). The overlay
  injects between those two points.

---

## 4. Cheat semantics: the opposite of GBC

**Every published PC Engine cheat is a RAM poke. None is a ROM patch.** There
is no Game Genie for this machine in the libretro database. That inverts the
split the Game Boy work is built around, and it is the single most important
fact in this plan.

Evidence, gathered 2026-08-25: all 397 files in libretro's
`NEC - PC Engine - TurboGrafx 16` were parsed and every one of the 1224 codes
in them read. None lands in ROM space. 1208 sit inside `0x1F0000`-`0x1F1FFF`,
the 8KB work RAM at bank `$F8`; 13 sit between `0x1F2000` and `0x1F2656`, which
is inside the 32KB a SuperGrafx carries and outside the 8KB this core will
keep, so the poker will have to decide whether to ignore them; 3 are not
addresses this machine has.

So the two mechanisms rank the other way round from GBC:

1. **RAM poke** (`cheat_poker.sv`) is **the feature**. Writes values into work
   RAM once per frame through dpram port B, triggered on PCE vblank, the
   equivalent of GBC's `vblank_irq`. Everything the corpus contains needs this
   and only this.
2. **ROM read override** (`CODES`) is **already wired and currently free**.
   Because nothing drives `gg_code`, Quartus folds the entire comparator away
   and it costs 0 ALMs. Leave it exactly as it is: unwired it costs nothing,
   and it is there if a ROM-patch code ever turns up. Do not spend a phase on
   it, and do not delete it either.

The libretro files come in two shapes, both targeting the same work RAM, and a
file uses one or the other.

**246 files** use `cheat0_code = "1f1548:64"`, a 21-bit hex CPU address and a
hex byte, with several joined by `+`.

**151 files** leave `cheat0_code` present and **empty**, and put the code in
`cheat0_address` as a **decimal offset into work RAM** plus `cheat0_value`,
converting as `0x1F0000 + address`. An earlier draft here said 47 files, all
named `(Rumbles)`. Both halves were wrong: there are 151 and 104 of them carry
ordinary game names, so a parser that keys on `_code` being present, or that
filters on the suffix, silently loses over a third of the corpus.

The parser has to read both, and has to skip the rows that cannot become a
poke: 70 with `cheat_type = 0`, which watch an address to fire a rumble and
write nothing, 2 bit-level rows, 1 with no value, and 3 with an impossible
address. It also has to expand `repeat_count`, which one row uses for real.
Full detail, and a decoder already written and tested against every file, lives
in the picker app's `docs/PCE-TG16-PLAN.md` and `cheatgui/pce.py`.

Enable state comes **from the cheat file**, via a `cheatN_enable` key, not from
menu checkboxes. GBC built per-cheat interact checkboxes and then removed them:
APF menu labels are fixed in JSON and the core cannot rename them, so generic
entries read "Cheat 1", "Cheat 2" and are useless. Do not repeat that.

---

## 5. The timing trap, known in advance

GBC's first working-parser build **missed setup by -3.374 ns**, and Quartus
still exited 0. Cause: `cpu_di` fed both the 32-way comparator and the mux
select, putting the entire comparator chain plus priority mux on the
late-arriving read data. The fix, worth **5.6 ns** there, was to split the
lookup so the 32-way search runs off the registered address and `cpu_di` feeds
only one 8-bit compare. The two forms are equivalent because `CODES` keeps at
most one entry per address.

Since §4 cuts the read override, that specific comparator is not being built
here. The transferable lesson still is: **any per-code lookup placed on a
late-arriving data path will cost nanoseconds**, and the poker has a lookup of
its own. Keep its table search off registered addresses rather than off data,
and check the report rather than trusting the exit code, because
`tools/podman/report.sh` gates on slack precisely for the reason above:
Quartus does not.

---

## 6. On-screen menu: nice to have, and the one genuinely new problem

`cheat_osd.sv` is parameterised `CELL = 6, COLS = 26, ROWS = 18` for a fixed
160x144 Game Boy screen. **The PC Engine has no fixed resolution.** Choosing its
output mode per game is the machine's defining trait, and this core's README
lists several supported widths. So the overlay cannot assume a raster.

Options, cheapest first:

1. Derive `COLS`/`ROWS` at runtime from the active display width the VCE
   reports, and centre the panel.
2. Draw the overlay in a fixed-size box positioned relative to the picture
   centre, letting it clip on the narrowest mode.
3. Draw into the linebuffer's own coordinate space rather than the output
   raster, so it inherits whatever scaling the core already does.

This is the reason the overlay is a nice to have. Everything up to and including
P4 is useful without it.

---

## 7. Explicitly out of scope

### 7a. CD-ROM² / disc images

Decided 2026-08-25: not now.

The RTL is all present and compiled every build (`rtl/pce/cd/`: `cd.vhd`,
`SCSI.vhd`, `SCSI_FIFO.vhd`, `CDDA_FIFO.vhd`, `MSM5205.vhd`) and produces zero
logic, because it is disabled in three places: `pce_top.vhd:636` passes the
literal `EN => '0'`, `main.sv:273` has `reg cd_en = 0` with every assignment
commented out, and roughly 85 further CD lines in `main.sv` are commented too.
MiSTer passes `EN => '1'` at that same spot; agg23 changed it when porting.

The reason it is a project rather than a toggle: MiSTer's CD block expects an
HPS running Linux to parse the cue sheet, seek the image and feed it sectors.
The Pocket has no HPS. `Mazamars312/openfpga-pcengine-cd` is the one core that
closed that gap, and its manifest shows the cost: `deferload` cue and bin
slots, APF `version_required 2.3` against our `1.1`, a System Card BIOS the
user must supply, and a 64KB `pce_mpu_bios.bin` for a soft MPU that stands in
for the HPS.

If CD becomes the priority, the cheaper direction is almost certainly to add
cheats to Mazamars312's core rather than add CD to this one. The CD subsystem
is the expensive half and it already exists there.

### 7b. Physical HuCards

Analogue does ship a TurboGrafx-16 adapter, and openFPGA cores genuinely can
read physical cartridges: `~/Desktop/repos/pocket-gbc` does exactly that, with
`"cartridge_adapter": "0x01000000"` in its `core.json` and the bus driven from
`core_top.sv:1008-1026`.

This core has it disabled two ways: `"cartridge_adapter": -1` in
`pkg/Cores/kroy.PC Engine/core.json`, and every `cart_tran_*` pin tied off at
`target/pocket/core_top.v:237-249` under the comment "cart is unused".

Leaving it that way, for one reason beyond scope discipline: the GB core spends
28 of the 30 available cart lines carrying 15 address plus 8 data. A HuCard
wants roughly 20 address plus 8 data plus control, which does not fit that
scheme, so Analogue's adapter must do something other than a passive pin remap.
What that something is does not appear in any public core, and it is a research
question rather than an RTL one.

Note this interacts with §2: `SGX_EN = 0` would permanently exclude SuperGrafx
HuCards, which the Analogue adapter does support.

---

## 8. Phasing

| Phase | Deliverable | Done when |
|---|---|---|
| **P0** | Confirm the fork and the SGX saving. | **Done 2026-08-25.** vanfanel costs -79 ALMs and gains 0.015 ns. SGX removal lands the core at 9,204 ALMs (49.8%) and 134 M10K (43.5%), timing met. See `docs/BASELINE.md`. |
| **P0.5** | `Swap ROM Bit Order` toggle for bit-reversed TurboChip dumps. | **Done 2026-08-25**, commit `66618f0`. Build verifying. |
| **P1** | **The poker, not the read override.** `cheat_poker.sv` writing work RAM through dpram port B at vblank, arbitrated with `COLD_RESET`, driven by one hardcoded address/value. | **Done 2026-08-26, verified on hardware.** R-Type "Auto Fire" (`1f016f:80`) applies through the full poker path on a real Pocket. 8,950 ALMs (48.4%), 134 M10K, timing met. `make dist` packages a flashable core. The first hardware test failed on a badly chosen cheat, not the mechanism: see `docs/CHEATS.md`. |
| **P2** | Cheats data slot + `cheat_loader.sv` + a third `data_loader`. Parser reads **both** libretro forms (§4). | **Built 2026-08-26.** Slot 2 at `0x50000000`, byte-wide. Whole-field key matching and optimistic commit with rollback: see `docs/CHEATS.md`. |
| **P3** | `interact.json` master switch, enables from the file. | **Done.** Menu matches the deployed GB/GBC core: `Cheats enabled` (`0x404`) and `Show cheats` (`0x408`), both off by default. The parsed-count readout was dropped rather than built; nothing needs it. |
| **P4** | ~~Reconnect the Game Genie read override.~~ **Cut.** Nothing in the corpus needs it and unwired it costs 0 ALMs. Revisit only if a ROM-patch code appears. | n/a |
| **P5 (stretch)** | `cheat_osd.sv` + font + titles, with §6 resolved. | The enabled list is readable on hardware across at least two PCE video modes. |
| **P6** | README, sample `.cht`, upstream anything that belongs upstream. **Also strip the two diagnostic entries** (`DEBUG Wipe Work RAM`, `Test Cheat`) from `interact.json`; the RTL behind them is parameterised off and can stay. | — |

Every phase after P0 is one commit with a hardware smoke test and a recorded
`report.txt`. Builds are ~19 minutes in `tools/podman/`, so batch RTL changes
rather than iterating one line at a time.

---

## 9. Open questions

1. ~~What cheat-code formats exist for PC Engine?~~ **Answered 2026-08-25**,
   see §4: two forms, 397 files, all RAM pokes. Remaining part: are there
   ROM-patch codes outside the libretro database? If not, §4 item 2 stays cut
   permanently.
2. ~~Does the `CODES` read override fire for HuCard reads here?~~ **Moot for
   now.** §4 found the corpus needs no ROM patching, so the override stays
   unwired and free. The question only matters if open item 1 turns up
   ROM-patch codes in the wild.
3. Is the 8KB work RAM the only poke target worth having, or do games keep
   state in the 32KB PRAM (`pce_top.vhd:609`, Populous only) often enough to
   matter?
4. ~~Does `SGX_EN = 0` want to shrink work RAM to `(13,8)`?~~ **Answered
   2026-08-25: no.** Quartus infers the 8KB memory by itself, because
   `RAM_A(14 downto 13)` is tied to `"00"` when `SGX = '0'`. `dpram:RAM` fell
   from 32 M10K to 8 with no source change. See `docs/BASELINE.md`.
