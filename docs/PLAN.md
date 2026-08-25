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

Remotes are configured with pushes disabled on both upstreams. Branches:

    master         tracks agg23, untouched
    agg23-base     agg23 + harness, holds the baseline measurement
    vanfanel-base  vanfanel + harness, the control build
    cheats         vanfanel + harness + SGX removal, the working line

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

Consequence: P1 below is uncommenting and rewiring, not re-porting.

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

## 4. Cheat semantics

Two mechanisms, same split as GBC:

1. **ROM read override** (`CODES`). Combinational compare of the CPU address
   against stored codes, forcing `genie_data` onto `CPU_DI`. Already wired.
   Correct for HuCard ROM patches.
2. **RAM poke** (`cheat_poker.sv`). Writes values into work RAM once per frame
   through dpram port B. Needed for anything that patches live state, which a
   read override cannot reach: DMA copies, cached values and read-modify-write
   sequences all diverge from what the code was written against. Use PCE vblank
   as the trigger, the equivalent of GBC's `vblank_irq`.

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

**Apply this from the first build, not after measuring.** This core's instance
is `ADDR_WIDTH => 21` against GBC's 16, so the comparator is wider and the
baseline hold margin here is already only 0.103 ns. `tools/podman/report.sh`
gates on slack precisely because Quartus does not.

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

## 7. Explicitly out of scope: physical HuCards

Analogue does ship a TurboGrafx-16 adapter, and openFPGA cores genuinely can
read physical cartridges: `~/Desktop/repos/pocket-gbc` does exactly that, with
`"cartridge_adapter": "0x01000000"` in its `core.json` and the bus driven from
`core_top.sv:1008-1026`.

This core has it disabled two ways: `"cartridge_adapter": -1` in
`pkg/Cores/agg23.PC Engine/core.json`, and every `cart_tran_*` pin tied off at
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
| **P1** | Reconnect the existing engine. Uncomment the `gg_code` loader shape at `main.sv:556-568`, drive it from a hardcoded constant code. Apply the §5 split-lookup fix at the same time. | A hardcoded code visibly takes effect on hardware. Proves the hook with no file I/O. |
| **P2** | Cheats data slot + `cheat_loader.sv` + a third `data_loader`. | A `.cht` next to the ROM applies codes. |
| **P3** | `interact.json` master switch + parsed-count readout, on a free `0x400+` bridge address. Enables come from the file. | Cheats can be turned off without removing the file. |
| **P4** | `cheat_poker.sv` against work RAM port B, arbitrated with `COLD_RESET`. | A RAM-poke code works where a read override does not. |
| **P5 (stretch)** | `cheat_osd.sv` + font + titles, with §6 resolved. | The enabled list is readable on hardware across at least two PCE video modes. |
| **P6** | README, sample `.cht`, upstream anything that belongs upstream. | — |

Every phase after P0 is one commit with a hardware smoke test and a recorded
`report.txt`. Builds are ~19 minutes in `tools/podman/`, so batch RTL changes
rather than iterating one line at a time.

---

## 9. Open questions

1. What cheat-code formats exist in the wild for PC Engine, and does the
   libretro `.cht` database cover it well enough to be the import path? GBC had
   2,456 files to test the parser against; the PCE corpus needs finding before
   P2 fixes a format.
2. Does the `CODES` read override even fire for HuCard reads here? The PCE
   fetches through `ROM_RD`/`ROM_A` out to SDRAM, so confirm `GENIE_DI` sits on
   the path the CPU actually reads, not a path the SDRAM controller bypasses.
   This is the single biggest unknown and should be answered in P1.
3. Is the 8KB work RAM the only poke target worth having, or do games keep
   state in the 32KB PRAM (`pce_top.vhd:609`, Populous only) often enough to
   matter?
4. ~~Does `SGX_EN = 0` want to shrink work RAM to `(13,8)`?~~ **Answered
   2026-08-25: no.** Quartus infers the 8KB memory by itself, because
   `RAM_A(14 downto 13)` is tied to `"00"` when `SGX = '0'`. `dpram:RAM` fell
   from 32 M10K to 8 with no source change. See `docs/BASELINE.md`.
