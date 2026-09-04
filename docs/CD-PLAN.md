# Plan: PC Engine CD by streaming the disc off the SD card

Goal: boot a Super CD-ROM² game, Rondo of Blood as the target, on this core,
with the cheat engine still working. `docs/PLAN.md` §7a ruled CD out of scope
on 2026-08-25 and recommended the opposite direction. This is the plan for
doing it here instead, and §4 keeps that other direction on the table.

**Input format is cue plus bin.** Decided 2026-08-30. Two formats are ruled
out and both matter, because the library on hand is in one of them.

*Not `.iso`.* A bare `.iso` is the MODE1 data track and nothing else, so Rondo
boots from one and plays silent: no soundtrack, no cutscene audio. Redbook
audio is most of what that disc is.

*Not `.chd`.* CHD is compressed, hunk by hunk, with zlib or LZMA or FLAC. There
is no offset arithmetic that turns an LBA into a byte range of a CHD, so none
of §3 applies to one: a sector cannot be fetched without decompressing the hunk
that holds it, and a hunk decompressor in the FPGA is a larger project than the
drive it would feed. Mazamars312's core reaches the same conclusion from the
other direction, saying CHD is out because the compression is too much for its
MPU.

**A CHD library converts on the way in, and that is a documented step rather
than a workaround.** Decided 2026-08-30:

    chdman extractcd -i "Castlevania - Rondo of Blood.chd" \
                     -o "Castlevania - Rondo of Blood.cue" \
                     -ob "Castlevania - Rondo of Blood.bin"

`chdman` ships in `mame-tools`. This costs disc space, roughly 540MB against
282MB for Rondo, and the card has room.

**Single bin, confirmed on the real output.** Rondo converted 2026-08-30:
282MB in, one 489MB bin and a 975 byte cue out, 22 tracks all indexing into
that one file. `--splitbin` is the opt-in for a file per track, so the default
is the single-file shape. The documented path therefore never changes files
mid-disc: `0x0192` runs once per disc rather than once per track, and the
reopen stutter in §6 stops being a risk for anything converted this way. It
stays a risk only for multi-bin redump sets, which people do have.

**The same output settles two things the parser cannot guess.** Rondo's cue:

    FILE "Castlevania - Rondo of Blood.bin" BINARY
      TRACK 01 AUDIO
        INDEX 01 00:00:00
      TRACK 02 MODE1/2048
        PREGAP 00:03:00
        INDEX 01 00:48:65
      TRACK 03 AUDIO
        PREGAP 00:02:00
        INDEX 01 03:04:14
      ... 19 more AUDIO tracks ...
      TRACK 22 MODE1/2048
        PREGAP 00:03:00
        INDEX 01 46:48:62

1. **Sector size is per track, not per disc.** The data tracks come out
   `MODE1/2048` and the audio tracks are 2352 by definition, so one bin holds
   both. There is no uniform `LBA * n` for this file. The TOC needs a sector
   size and a running byte offset per track, and the fetch needs the multiply
   that goes with the track it is in, which is what `pcecdd.cpp` does and what
   §2 lists as `+16 to skip the header on 2352 data sectors`. An earlier draft
   of §4B assumed one sector size for the whole image; that assumption is
   what a real cue just refuted.
2. **`PREGAP` occupies LBA space and no file bytes.** It is generated silence,
   not stored data, unlike an `INDEX 00` gap which is in the file. Rondo has
   three of them. Get this wrong and every LBA from track 2 onward is 225
   sectors out, which is a disc that mounts and then reads garbage.

Note what this costs §4B: a flat container with one sector size would have to
re-pad the 2048 byte data tracks up to 2352, so the file grows rather than
matching the bin it came from.

Everything below assumes the cue and its bins.

---

## 0. The cheat half is already done

Rondo's libretro file is `NEC - PC Engine CD - TurboGrafx-CD/Akumajou Dracula
X - Chi no Rondo (SCD) (Japan).cht`. Read 2026-08-30, five codes:

    1f008d:09            Infinite Lives
    1f0094:99            Infinite Hearts
    1f0098:70            Infinite Health
    1f1460:01            Invincibility
    1f0096:99+1f0097:99  9999 Credits

All five are the hex form `cheat_loader.sv` already parses, all five land in
`0x1F0000`-`0x1F1FFF`, which is the 8KB work RAM `cheat_poker.sv` already
writes through dpram port B, and one uses the `+` join the loader already
handles. Nothing in the cheat stack needs a line changed for CD.

The whole job is the disc.

## 1. What the repo already carries

| Piece | State |
|---|---|
| `rtl/pce/cd/` | compiles every build, costs 0 logic |
| `pce_top.vhd:719` | `EN => CD_EN and AC_EN`, and `CD_EN` arrives as `'0'` |
| `main.sv:321` | `reg cd_en = 0`, ~85 CD lines commented around it |
| `pce_audio` | already mixes `cdda_sl/sr` and `adpcm_s` |
| `interact.json` | has `PCM Audio Boost` at `0x304`, which is the ADPCM control |
| `core_top.v:367` | `cd_audio_boost` at `0x308` is wired and has **no menu entry**, so P6 has to add one |
| `main.sv:531-539` | the SDRAM read/write mux on `cd_ram_a` is live, not commented |
| `pce_top.vhd:709` | `CD_RAM_A` maps Super System Card RAM and Arcade Card RAM into SDRAM |
| `core_bridge_cmd.v:133-155` | target command registers and `tstate` FSM exist, issuing `0x0140` |
| `cheat_loader.sv` | **an ASCII parser for a text file arriving through a data slot, working on hardware** |

That last row is the one that decides §4. A cue sheet is a smaller ASCII
grammar than a libretro `.cht`, and this core already parses one of those in
RTL.

Headroom, from `docs/BASELINE.md`: 8,950 ALMs (48.4%) and 134 M10K (43.5%)
used. About 9,500 ALMs and 174 M10K free, all of it bought by `SGX_EN = 0`.
Mazamars312's core states SuperGrafx does not fit alongside CD on this device,
so that price is already paid here.

## 2. What is missing: the drive

MiSTer's `cd.vhd` is only the CD interface chip. The drive behind it lives on
the HPS, in `Main_MiSTer/support/pcecd/pcecdd.cpp`, about 900 lines:

* SCSI commands TESTUNIT, REQUESTSENSE, GETDIRINFO, READ6, MODESELECT6,
  SAPSP, SAPEP, PAUSE, READSUBQ
* cue sheet parsing: FILE, TRACK (MODE1/2048, MODE1/2352, AUDIO), PREGAP, INDEX
* LBA to file offset, per track, per sector size, `+16` to skip the header on
  2352 data sectors
* BCD and MSF conversion, 150 sector lead-in
* CD-DA streaming, 2352 audio bytes plus 98 subcode bytes per sector, byte
  swapped
* seek latency modelling

The Pocket has no HPS. All of that has to move into the FPGA.

## 3. The transport

Three APF target commands carry it, and the second and third are what make
native cue plus bin possible.

**`0x0180` Data slot read.** Four parameter words: slot id, offset, bridge
address, length. Result 0 ok, 1 undefined slot, 2 out of range. `0x0181` is the
48-bit form for files past 4GB. The slot must be marked **deferload** so APF
does not preload it; APF still fills in the size table.

**`0x0190` Get filename of data slot.** Parameters: slot id, and a pointer to a
`get_dataslot_file_t`, which is 256 bytes of null-terminated **absolute** path,
written by the host. So the core can learn where the user's cue actually lives,
for example `/Assets/pce/common/Rondo/Rondo.cue`, and take the directory off it.

**`0x0192` Open new file into data slot.** Parameters: slot id, and a pointer to
an `open_dataslot_file_t`: 256 bytes of absolute path, 4 bytes of flags (bit 0
create, bit 1 resize), 4 bytes of size. Result 0 opened, 1 created and opened,
2 slot undefined, 3 not found, 4 malformed path, 5 error.

Chained, that is the whole file story:

1. User picks the `.cue`. It is tiny, so it rides an ordinary preloaded slot.
2. The core parses it.
3. `0x0190` on that slot gives the absolute path; keep the directory.
4. For each `FILE` in the cue, `0x0192` opens `<dir>/<name>` into the deferload
   streaming slot.
5. `0x0180` pulls sectors out of whichever bin is currently open.

Mazamars312's core does the same shape, requesting the cue and then loading the
bins the cue names, and reports 99 tracks working, which is the practical
confirmation that step 4 holds up.

Consequences:

* `core.json` `version_required` went from `1.1` to `2.3` in P0, matching
  Mazamars312's manifest. The true minimum is still unconfirmed and wants
  pinning before release. Older Pocket firmware will not load the core, which
  the README and the release notes now say.
* `core_bridge_cmd.v` gains three cases in the target FSM. The register file and
  the FSM already exist, so this is an extension, not the rewrite the module
  header invites.
* The core has to expose bridge-addressable RAM for the sector buffer and for
  the two 256-byte path structs, and the path struct is written by the host for
  `0x0190` and read by the host for `0x0192`, so it needs both directions.
  `mf_datatable` in `core_bridge_cmd.v` is the precedent. `0x10000000`,
  `0x20000000` and `0x50000000` are taken; `0x60000000` is free.
* Multi-bin redump sets and single-bin community images both work, because
  nothing assumes one file.

## 4. Three routes

### A. Native cue and bin (recommended)

Parse the cue in RTL, in a module built the way `cheat_loader.sv` was, and use
§3 to open and stream the bins it names. The user drops in the files they
already have and picks the cue.

The cue grammar the drive actually needs is FILE, TRACK with its sector size
and type, PREGAP and INDEX. That is fewer shapes than the two libretro `.cht`
forms the cheat loader already handles, and the output is a TOC in BRAM rather
than a code table.

### B. Flatten it on a PC first

A tool under `tools/cd/` converts cue plus bins into one file with a TOC header
and every track at 2352 bytes contiguous by LBA, so the core only ever does
`offset = header + LBA * 2352`. No parser in hardware.

Was the recommendation until `0x0190` and `0x0192` turned up. It now costs a
conversion step, a duplicate ~540MB image per game, and a second file format to
document, to avoid a parser this repo has already written once. Keep it as the
fallback if real cues turn out to be worse than §4A assumes: a converter is a
day of Python, and a wrong RTL parser is a 19 minute build per hypothesis.

### C. Put the cheats on Mazamars312's core instead

What `docs/PLAN.md` §7a already recommends. The port is five modules, the two
menu entries and the data slot. CD is the expensive half and it exists there.

Against it: that core is 0.2.3-BETA, last touched 2024-09, separate lineage
from this one, and taking it on means maintaining a second base alongside the
four cores already in the tree. It also gives up vanfanel's accuracy fixes,
which `docs/PLAN.md` §0 measured as strictly better.

**Recommendation: A.** C was the fallback if P0 failed, and P0 passed.

## 5. Phasing

| Phase | Deliverable | Done when |
|---|---|---|
| **P0** | **Measure the transport first.** `0x0180` in `core_bridge_cmd.v`, one deferload slot, a counter that reads back to back and reports KB/s. No CD RTL touched. | **Done 2026-09-01, passed on hardware.** 1104 KB/s at 8KB requests, 6.3x CD-DA, no errors. See §5a. |
| **P0.5** | One build with `EN => '1'` and nothing else, to price the CD block. | **Done 2026-09-01.** Fits: 11,575 ALMs (62.6%), 224 M10K (73.0%), timing met. See §5f. |
| **P1** | `0x0190` and `0x0192`, plus the path struct RAM. Prove it by opening a bin the cue names and reading its first sector. | **Done 2026-09-01, passed on hardware.** `G0 O0 R0 L033 P62696E00`. See §5b. |
| **P2** | `cd_toc.sv`, the cue parser, modeled on `cheat_loader.sv`. TOC in BRAM: per track, start LBA, sector size, type, byte offset. | **Written 2026-09-01 and verified in simulation** against the real Rondo cue, all 22 tracks. See §5d. Not yet wired in or run on hardware. |
| **P3** | `cd_host.sv`: answers `CD_COMM` with `CD_STAT`/`CD_MSG`/`CD_DOUT`, LBA to offset, sector fetch, `CD_DATA`/`CD_DATA_WR`/`CD_DATA_END`. Data track only, no audio. Uncomment `main.sv`, wire the SDRAM `CD_RAM` path, drive `CD_EN` from a loaded cue. | The System Card reaches its menu and a game reads sector 0. |
| **P4** | CD-DA: prefetch ring, `CD_AUDIO_WR` at rate, SAPSP, SAPEP, PAUSE, READSUBQ. | **Streaming done 2026-09-02, verified on hardware.** Rondo's CD audio plays: 89 chunks/s against 86 needed, 2.81 ms a read, 25% duty. See §5j. The drive *state* around it was wrong, which §5k covers. |
| **P5** | ADPCM, REQUESTSENSE, MODESELECT6, seek latency. | Rondo is playable start to finish. |
| **P6** | Slots and menu: System Card BIOS, cue slot, deferload disc slot, Region toggle, CD RAM and BRM save. Verify the five §0 cheats on hardware. | Cheats apply on a CD game. |
| **P7** | README, docs, release. | not started |

## 5a. P0 as built

Six files, no CD RTL touched, nothing in `rtl/pce/cd/` enabled.

| File | Change |
|---|---|
| `target/pocket/dataslot_probe.sv` | new. Issues back to back `0x0180` reads for one second and counts what arrives |
| `target/pocket/core_bridge_cmd.v` | target command `0x0180`, in the FSM and register file that were already there |
| `target/pocket/core_top.v` | `CD_PROBE` localparam, the probe, the `0x40C` switch, the crossing into the overlay clock |
| `rtl/pce/cheat_osd.sv` | `DIAG` parameter. Replaces the header line with the probe result |
| `pkg/Cores/kroy.PCE/data.json` | slot 100, `deferload: true`, no address |
| `pkg/Cores/kroy.PCE/core.json` | `version_required` 1.1 to 2.3 |
| `pkg/Cores/kroy.PCE/interact.json` | `DEBUG SD Read Probe` at `0x40C`, `DEBUG Probe Chunk` at `0x410` |

`deferload` turned out to be a top level key on the slot rather than a bit in
`parameters`, and a deferload slot carries no `address` because nothing is
preloaded. Checked against Mazamars312's `data.json`.

To run it: put any file of at least 8MB in slot 100, turn on **Show cheats**
so the overlay is drawn, then toggle **DEBUG SD Read Probe**. The header line
becomes

    KB/S 01234 LAT 00056 E0 C1

KB/S is exactly that, measured over one second of `clk_74a`, which is why
there is no divider in the module. LAT is the worst single request in the run,
in units of 1024 clocks, so one count is 13.8 us. E is the last non-zero
result code from `0x0180`: 1 is an undefined slot, 2 is out of range, and a
run stops at the first one rather than reporting a rate it did not measure. C
is the request size the run used.

Bytes are counted as bridge writes landing in the probe's window, not as
requests the host said it completed, so a host that acknowledges a read and
delivers nothing reads as zero rather than as a pass. Nothing answers at that
window, and unclaimed bridge writes go nowhere, which is why the probe costs
no block RAM.

Request size is swept from the menu rather than rebuilt: **DEBUG Probe Chunk**
picks 0 for 512 bytes, 1 for 2048, 2 for 8192, and the value is latched at the
start of a run so turning it mid-measurement cannot mix two sizes into one
number. The size that produced the answer is printed as the `C` digit, because
three runs at three sizes are otherwise three numbers with nothing to tell them
apart. 2048 is one request per sector; larger amortises the per-request cost
but makes one stall wider.

**`CD_PROBE` is 1 in the working tree and must be 0 before any release.** At 0
the probe, its target command traffic and the overlay branch all fold away.

### The P0 result: pass

Measured 2026-09-01, Rondo's 489MB bin in slot 100, all three request sizes:

    KB/S 00453 LAT 03237 E0 C0
    KB/S 00694 LAT 03363 E0 C1
    KB/S 01104 LAT 00946 E0 C2

| | bytes | KB/s | req/s | mean | worst | x mean |
|---|---:|---:|---:|---:|---:|---:|
| C0 | 512 | 453 | 906 | 1.10 ms | 44.64 ms | 40.4 |
| C1 | 2048 | 694 | 347 | 2.88 ms | 46.38 ms | 16.1 |
| C2 | 8192 | **1104** | 138 | 7.25 ms | 13.05 ms | 1.8 |

No errors at any size, and a non-zero rate with `E 0` says the bytes arrived at
the bridge window rather than the host merely acknowledging the reads.

**The gate is cleared with room.** The bar was 400 KB/s. Even the worst
configuration beats it, and 8KB requests give 1104 KB/s: 6.3x CD-DA on its own,
or 3.4x CD-DA plus a data track reading alongside it. Every phase after this
one is worth building.

**Request size matters more than expected, and it saturates.** Fitting the
three points gives roughly **0.69 ms of fixed cost per request** and a
**streaming ceiling near 1221 KB/s**. At 512 bytes the fixed cost is 63% of
each request and the transport spends its time on overhead. At 8192 it is 10%
and the rate is within 10% of the ceiling, so going past 8KB buys almost
nothing. **The fetcher should use 8KB reads**, which is four sectors of 2048.

**The worst case is a fixed event and does not scale with the request.** 44.6
and 46.4 ms at C0 and C1, near enough identical across a 4x change in size,
which is a card or host doing housekeeping rather than anything proportional
to the transfer. **Do not read C2's 13 ms as immunity.** C2 makes only 138
requests in the window against C0's 906, so the likeliest explanation is that
it did not happen to hit the stall, not that 8KB requests avoid it. The safe
reading is that a ~46 ms stall can land on any request at any size.

**Consequence for P4: the ring is sized against the stall, not the rate.** 50
ms of CD-DA is 8.8 KB, so a 32KB ring covers the audio with the data track
alongside, and 64KB is generous at 4 M10K of the 171 free. Sizing it off the
1104 KB/s average instead would give a buffer that underruns a few times a
minute, presenting as flaky hardware or a bad card rather than as a design
error.

### The P0 build

Built on `kira` 2026-08-30, 799 s, **timing met**.

| | P0 probe build | diag, `docs/BASELINE.md` |
| --- | ---: | ---: |
| quartus | 21.1.1 Lite | 25.1std |
| ALMs | 9,821 (53.1%) | 8,950 (48.4%) |
| Registers | 11,095 | 10,100 |
| M10K | 137 (44%) | 134 (43.5%) |
| Worst hold | +0.092 ns | +0.103 ns |

**Do not read the delta as the cost of the probe.** The two builds are four
years of Quartus apart: the runners carry `raetro/quartus:21.1` and the
baseline was measured with the local `pocket-quartus:25.1std` image. 871 ALMs
is the probe plus the toolchain, in unknown proportions. Pricing anything
properly, P0.5 included, needs 25.1 on a runner first.

Two harness fixes came out of the run, both in the repo rather than on the
runner:

* `--userns=keep-id` is rootless-only and a runner is root, so podman refused
  outright. The flag is now keyed on the uid. Written as an `if` rather than
  `[[ ]] && USERNS=()`, because under `set -e` a false test in that position
  takes the whole build down with it.
* `dist.sh` needs `jq`, which the runner does not have. Packaging happens on
  the host instead: it only wants the `.rbf` and `pkg/`, so nothing has to be
  installed on the runner to get a flashable core.

**P0 go/no-go.** CD-DA alone is 176.4 KB/s sustained, and the data track reads
on top of it. Call the bar 400 KB/s sustained with worst-case per-request
latency small enough to hide behind a prefetch buffer of a few hundred KB.
No published figure for APF `0x0180` throughput was found, so it has to be
measured. Nothing after P0.5 is worth building until that number exists.

## 5b. P1 as built

`0x0190` and `0x0192` plus the struct RAM, in `dataslot_path.sv`. It runs the
whole chain with no parser in the way: ask where slot 100's file is, scan the
returned path for its last dot, rebuild it with `bin` in place of the
extension, open that into slot 101, read its first sector. P2's parser replaces
the extension swap with a real filename out of the cue and nothing under it
changes.

The target command port in `core_bridge_cmd.v` was generalised on the way:
a command number and four parameter words, rather than the `0x0180`-shaped
port P0 added, because P1 alone needs three commands. The two diagnostics share
it through an arbiter in `core_top.v`.

Manifests: slot 101 `Disc data`, deferload and not user-pickable since the
core opens it rather than the user, and `DEBUG Path Probe` at `0x414`, taking
`interact.json` to 15 of 16 variables.

Built on `kira` 2026-09-01, 841 s, timing met.

| | P0 | P1 | delta |
| --- | ---: | ---: | ---: |
| ALMs | 9,821 (53.1%) | 10,324 (55.9%) | +503 |
| M10K | 137 (44%) | 139 (45%) | +2 |
| Registers | 11,095 | 11,450 | +355 |
| Worst hold | +0.092 ns | +0.092 ns | 0 |

### The P1 result: pass

2026-09-01, cue loaded into slot 100:

    G0 O0 R0 L033 P62696E00

| | |
|---|---|
| `G0` | `0x0190` returned the path |
| `O0` | `0x0192` opened a file the user never picked |
| `R0` | `0x0180` read a sector out of it |
| `L033` | 51 bytes, exactly `/Assets/pce/common/Castlevania - Rondo of Blood.cue` |
| `P62696E00` | the rebuilt word past the dot: `b`, `i`, `n`, NUL |

The file layer is proven. The core can be handed one file by the user, find out
where it lives, and open a sibling it was never given. That is everything P2's
parser needs underneath it, and P2 now only has to replace one extension swap
with a filename read out of the cue.

**What actually fixed it was the bridge read, and the `P` field is what proved
it.** The struct RAM originally presented its output into `core_top`'s read mux
one cycle after the address changed, with no output register, which only
answers correctly if the bridge settles an address before asserting
`bridge_rd`. `core_bridge_cmd` never relied on that: it registers the address
in and the data out. Matching that pattern was the fix.

`P62696E00` says the path being built was correct all along, through both
failing builds. Without it, "the string is wrong" and "the string is right and
the host read it wrong" produce an identical `O4`, and the only way to tell
them apart is to guess and spend fourteen minutes finding out. Two diagnostics
in this phase paid for themselves the same way: `L000` versus `L033` separated
a command that never issued from one that did, and `P` separated the builder
from the reader.

**The rule this phase earned:** every result code on a diagnostic line needs a
neighbouring field that shows what the operation actually operated on. A code
alone cannot distinguish a failure from a lie.

### The false pass, which cost another

First hardware run, 2026-09-01, cue loaded into slot 100:

    G0 O4 RF L000 00000000

`0x0190` reported success, the buffer it was supposed to fill was empty, and
`0x0192` then called the all-zero path malformed. `G0` was the lie.

The two diagnostics share one target command port through a select in
`core_top.v`. The select is a register, so it settles a cycle after a module
raises its request, but the request reaching `core_bridge_cmd` was wired as
`path_req | probe_req`, bypassing it. The command was therefore accepted on the
first cycle, while the select still pointed at the throughput probe, and went
out as that module's constant `0x0180` with four zero parameters: read slot 0,
offset 0, length 0, which the host returns 0 for. `dataslot_path` recorded a
`0x0190` that never happened and scanned a buffer nothing had written.

Only the first command of a burst can be misissued, because the select catches
up and then holds, which is why this produced a plausible line rather than a
hang. The fix takes the request through the same select as the parameters, so
an unsettled cycle presents the idle module's request, which is low.

The lesson, and it is not the one the earlier fix taught: **a latched select
has to gate every signal the transaction depends on, the request included.**
The register was added deliberately to fix an arbitration hazard, and left a
second one beside it in the same block.

Worth carrying into P3 especially, where the drive model answers `CD_COMM` and
feeds `CD_DATA` while the ring is being refilled: **a diagnostic that can
report success for a command it never issued is worse than one that fails.**
Anything reporting a result code should report it alongside evidence that the
command ran, which is what `L000` did here.

### The inference trap, which cost a build

The first P1 did not fit: **2021 LABs required against 1848 on the device.**

The struct RAM was written as one 256 word array with **two write ports inside
a single always block**, one for the bridge and one for the state machine.
Quartus inferred no memory from it and built 8,192 flip-flops with the muxing
to address them. It does not warn. The evidence is in the synthesis summary
rather than the error: registers went 11,095 to 19,195 while block memory bits
did not move at all.

The fix is two memories with exactly one writer and one reader each, which is
the shape that always infers, and which the problem wanted anyway: the host
only ever writes the get struct and only ever reads the open struct. Block
memory bits then rose by exactly 6,144, which is 64x32 plus 128x32, and the
module came out at 503 ALMs.

Two lessons worth carrying into P2 and P3, where the TOC and the CD-DA ring are
both memories:

* **A memory with more than one writer is a memory that might not be a
  memory.** Give every inferred RAM one writer and one reader, and split the
  structure until that is true.
* **Verilator cannot answer this.** It lints the two-write-port version
  happily; it caught real width and index bugs in the same files, but
  inference is a Quartus-only question. Lint first because it is two minutes
  against fourteen, then expect the fitter to be the one that finds this class.

`docs/PLAN.md` §5 records the same shape of trap for timing: Quartus exits 0 on
a design that misses timing, and it builds logic silently for a memory it will
not infer. Read the report, not the exit code.

## 5c. P2 design, before writing it

`cheat_loader.sv` is the template, and reading it settles three things.

**The cue slot stops being deferload.** A deferload slot is never loaded, which
is the whole point of it for a 489MB bin, but it also means the bytes never
arrive in the core. The cue is 975 bytes. So slot 100 becomes an ordinary
preloaded slot with a bridge address, fed to `cd_toc.sv` through a
`data_loader` exactly as slot 2 feeds `cheat_loader`, and only slot 101, the
bin, stays deferload. `0x0190` still reports the path of a preloaded slot, so
nothing P1 proved is given up.

Use `WRITE_MEM_CLOCK_DELAY(4)` and `WRITE_MEM_EN_CYCLE_LENGTH(1)`, as the cheat
slot does, not the ROM loader's 32 and 16: APF delivers a 32-bit word about
every 75 `clk_74a` cycles and a byte-wide drain has to stay ahead of it.
`0x10`, `0x20` and `0x50` are taken by the existing slots and `0x60` and `0x61`
are P0's and P1's bridge windows, so the cue wants `0x30000000`.

**There is no end-of-file signal, so the TOC has to be correct after every
byte.** `data_loader` provides none and `cheat_loader` is built around its
absence. The same applies here, and it rules out any design that computes the
track table in a pass at the end.

**Byte offsets are a recurrence, and `PREGAP` is not in it.** Per track the
parser needs the `INDEX 01` time and the sector size from the `TRACK` line.
With L for start LBA and S for sector size:

    base(k) = base(k-1) + (L(k) - L(k-1)) * S(k-1)

and a sector inside track k sits at `base(k) + (LBA - L(k)) * S(k)`.

An earlier draft of this section said the opposite, that a `- pregap(k)` term
was the one that mattered because a pregap occupies disc addresses and no file
bytes. **That is the textbook reading of a cue and it is wrong for the images
this core takes.** `chdman extractcd` writes the whole disc, pregaps included,
and states them in the cue only to describe the structure.

Settled by arithmetic against the real file rather than by reasoning, because
both models look right and differ by only a few hundred KB. Rondo's bin is
512,871,728 bytes, 22 tracks, pregaps on 2, 3 and 22:

| model | bytes before track 22 | remainder | in 2048 byte sectors |
|---|---:|---:|---:|
| subtract pregaps | 491,026,128 | 21,845,600 | 10666.8 |
| ignore pregaps | 492,391,728 | 20,480,000 | **10000.0** |

A whole number of sectors is only possible one way. Had this gone in on the
textbook reading, every track after the first would have been 225 to 375
sectors out and the disc would have mounted and then read garbage, which is
the hardest class of bug to attribute.

Techniques worth taking verbatim from `cheat_loader`: `S_SKIP` as the
catch-all, so `REM`, `CATALOG`, `PERFORMER`, `ISRC` and `FLAGS` cost nothing;
whole-length keyword matching against a `key_ok` vector, since prefix matching
is what made it read the wrong field and look like it worked; and a structural
bound, one `room` term in the commit predicate, so no cue can overflow the
table however malformed it is.

## 5d. P2 as built

`rtl/pce/cd_toc.sv`, the cue parser. Not yet wired into the core.

Verified in simulation against the real Rondo cue rather than on hardware,
which for a pure parser is the stronger test: every one of its 22 tracks was
checked against an independent model, and track 22's byte offset of
492,391,728 leaves exactly 10,000 sectors of 2048 to reach the file's real
size of 512,871,728.

Simulation also found a bug that a hardware smoke test would probably have
missed. A second cue was written to be awkward on purpose: CRLF line endings,
`REM`, `PERFORMER`, `TITLE`, `FLAGS`, `ISRC` and `POSTGAP` noise, tab indents,
a filename full of dots, an `INDEX 00`, and **no trailing newline on the last
line**. The last track vanished. The parser committed a track on the character
that terminated its `INDEX` line, and a file is not obliged to have one.

The fix is to commit on every digit of the frames field, each one rewriting the
same entry with a better answer, so the table is correct after every byte
rather than after every line. That is exactly what the module's own header says
the absence of an end-of-file signal demands, and the first draft did not do
it. `prev_lba`, `prev_base` and `prev_size` are promoted only on the
terminator, because they must stay the state *before* the current track or each
digit would accumulate onto the last one's answer. A file ending mid-number
never reaches the promotion and does not need to: there is no following track
for it to serve.

`PREGAP` is not parsed at all, per the correction in §5c, so the grammar is
`FILE`, `TRACK` and `INDEX` and everything else falls into the skip state for
free.

### P2 on hardware: pass

2026-09-01, Rondo's cue loaded into `Disc (cue)`:

    TRACKS 22 LAST 1D594D30

`0x1D594D30` is 492,391,728, byte for byte what simulation produces, and
512,871,728 minus it is exactly 10,000 sectors of 2048. That one number is the
accumulation of all 21 tracks before it, so the parse, the offset recurrence
and the table read-back are all correct on real hardware.

10,790 ALMs (58.4%), 140 M10K, 21 DSP, timing met at +0.090 ns.

Three builds, and each failure was a different kind:

1. **Missed timing by 5.445 ns.** `docs/PLAN.md` section 5 word for word: the
   incoming byte fed `f_next`, then MSF to LBA through two multiplies, a 32 bit
   subtract, a 32 by 12 multiply, an add and a mux, all before the first
   register. `clk_sys_42_95` fell to an Fmax of 35.99 MHz. Fixed by a four
   cycle commit sequencer, each stage one operation between two registers.
   It costs nothing: `data_loader` delivers a byte every few cycles and the
   sequencer is idle again before the next one arrives.
2. **Two drivers on one register.** Splitting the parser and the sequencer into
   separate `always` blocks left `c_pend` and `c_promote` written by both.
   Merged into one block, which also states the priority: the sequencer runs
   first and the parser second, so a request raised on the cycle one is
   consumed survives.
3. **The table was never built.** The second build's block memory bits did not
   move at all. `rd_track` was tied to a constant with every read output
   unconnected, so Quartus deleted all three memories, and the build would have
   proven the arithmetic and nothing about the storage. The diagnostic now
   reads the table back through the read port, so the number only appears if
   the memory works.

Note (3) carefully: **only `base_mem` is built even now**, 3,168 bits and one
M10K, because only `base_q` is read. `lba_mem` and `att_mem` are still removed
as unused and will appear when P3 connects the drive model. What this proves is
that the pattern infers into an M10K rather than into flip-flops, which is what
went wrong in P1, not that all three memories are exercised.

The recurring shape across P1 and P2 is worth stating once: **verilator lints
and simulates all of this correctly and has nothing to say about inference,
timing closure or multiple drivers.** Simulation proves the parser is right;
the fitter proves it is buildable; they fail in disjoint ways and both are
needed.

## 5f. P0.5: what the CD block costs

Built on `kira` 2026-09-01 with `pce_top.vhd:670` changed from `EN => '0'` to
`EN => '1'` and nothing else. **Quartus 25.1std**, so unlike every other build
in this phase it is directly comparable to `docs/BASELINE.md`. 850 s,
**timing met at +0.070 ns**.

| | cheats only, 25.1 | with the CD block, 25.1 |
| --- | ---: | ---: |
| ALMs | 8,950 (48.4%) | **11,575 (62.6%)** |
| M10K | 134 (43.5%) | **224 (73.0%)** |
| Block memory bits | | 1,757,560 (56%) |
| DSP | 17 | 24 |
| Worst hold | +0.103 ns | +0.070 ns |

**It fits, with 6,905 ALMs and 84 M10K left.**

### The memory cost is exactly attributable

Block memory rose by 688,128 bits over the P2 build, and that number is not
approximate:

    ADPCM buffer   64KB   524,288 bits
    CDDA FIFO      4096 x 32   131,072
    SCSI FIFO      4096 x 8     32,768
                          ---------------
                          688,128  exact

So the three memories the specification predicted are the entire block-RAM cost
of the CD block, with nothing unaccounted for. The ~52 M10K estimate for ADPCM
was right in isolation; the FIFOs add the rest to 84 blocks.

### The symmetry worth noticing

The stock core before SuperGrafx was removed sat at **225 M10K (73.1%)**. With
CD enabled it sits at **224 (73.0%)**. Dropping SuperGrafx freed almost exactly
what PC Engine CD needs. That is coincidence rather than design, but it means
the trade recorded in the README is now literally true in both directions: the
second VDC's block RAM is what CD is being built out of.

### What is left for P3 and P4

* **84 M10K.** A 32KB audio ring is 26 of them, leaving 58.
* **6,905 ALMs** for `cd_host.sv` and the sector fetcher.
* Timing at +0.070 ns is the tightest of the phase, and that is *before* the
  drive model exists. This is the number to watch, not the ALM count.

**This is a floor, not the final cost.** With `EN => '1'` and the host ports
still commented out in `main.sv`, the CD block's inputs are tied low and some
logic folds that a real host would keep alive. The three memories are
structural and exact; the ALM figure will grow when the ports are connected.

## 5e. P3 specification, from the RTL and the reference

Five parallel reads of `cd.vhd`, `SCSI.vhd`, `pcecdd.cpp`, the SDRAM path and
`pce_top.vhd`. What they settle, before any of it is written:

### The drive is a tick engine

13.33 ms per tick, which is 75 Hz single speed, throttled to 16 ms per tick
while a data read is in progress. Every latency in the reference is counted in
ticks. So `cd_host.sv` is a tick counter with a command decoder beside it, not
a per-command state machine.

### The protocol, exactly

* `CD_COMM_SEND`, `CD_DOUT_SEND` and `CD_DATA_END` are **one-clock pulses**.
* `CD_STAT_GET` and `CD_DOUT_REQ` are level-sampled into sticky flags: pulse
  for one clock, never hold, or the core issues status phases forever.
* `CD_STAT` is sampled about **1.05 ms** after the pulse and `CD_MSG` about
  **2.2 ms** after. Set both before pulsing and hold them until the next
  command.
* Phase arbitration is strict priority, `SEL_N` then status then data then
  data-out. **Pulsing `CD_STAT_GET` while sector bytes are still queued makes
  the status jump the queue** and the rest of the data arrives after the
  message. Order is: command, all data, `CD_DATA_END`, then status.
* CDB length comes from a table indexed by the **opcode's high nibble**, not
  SCSI group codes. The vendor opcodes `0xD8` `0xD9` `0xDA` `0xDD` `0xDE` are
  all 10 bytes. Bytes above the CDB length are stale from the previous command
  and must be masked.
* Everything is on `clk_sys_42_95`, so the sector path crosses from the bridge
  clock.

### What is simpler than expected

* **The message byte is always 0x00**, and only GOOD and CHECK CONDITION are
  ever sent. Sense is set in exactly two places: TESTUNIT with no disc, and an
  unknown opcode.
* **Subcode is not needed at all.** `cd.vhd` has no subcode port. The 98 byte
  packets, the bit-reversed CCITT CRC and the eight-channel interleave in the
  reference all go to a MiSTer channel this core does not have.
* **The seek model can wait.** It is a 14 group CLV table, and the reference
  has a fast-seek path that sets latency to zero.
* **Slots 0 and 1 need no manifest change.** The System Card is a 256KB image
  through the ordinary HuCard ROM path, and CD backup RAM is the same 2KB
  object at the same address as HuCard backup RAM.
* **Leave `AC_EN` at 0.** The Arcade Card prunes cleanly and independently, and
  it would cost 2MB of SDRAM, a 32-bit barrel shifter and rotator, and about
  385 flops for four games.

### What is harder than expected

* **The ADPCM buffer is 64KB of on-chip RAM**, `cd.vhd:629`, about **52
  M10Ks**. At 140 of 308 used today that lands the core near 192 before the
  drive model has a single register. It is not optional even for plain
  CD-ROM2.
* **`READ6` and `PAUSE` flush the entire CDDA FIFO** through `STOP_CD_SND`. So
  the core's 92.9 ms of audio buffering is zero again after every data sector,
  and the host must re-prime 16KB from its own memory. This is what makes a
  32KB host ring necessary rather than optional, and it corrects an earlier
  note here that the core FIFO alone covered the 46 ms stall.
* **Underrun ends a transfer silently.** An empty SCSI FIFO at any byte
  boundary pulses `CD_DATA_END`, which the CPU reads as end of transfer. A
  short read looks like a successful short read.
* **`K[7]` is `not CD_EN`**, the CD-unit presence bit every read of `$1000`
  returns. So `cd_en` is a per-load mode bit, not a global setting: a HuCard
  game that branches on it would take the CD path and find nothing.

### The minimal change list

1. `pce_top.vhd:670`, `EN => '0'` becomes `EN => CD_EN`. Nothing else matters
   until this changes.
2. `main.sv:321-325`, uncomment the `cd_en` driver, keeping its clear on
   `cart_download`.
3. `main.sv:228-252`, reconnect the `CD_RAM_*` and CD status, command and data
   port groups. They are floating inputs and dangling outputs today.

On (3): `cd_ram_a`, `cd_ram_rd`, `cd_ram_wr` and `cd_ram_do` are **undriven in
the shipping core** yet are consumed by the live SDRAM expressions. Quartus
ties them low and the build behaves, so today's correctness rests on a
synthesis default rather than on the RTL. Reconnecting the port group fixes it
as a side effect.

`pce_top.vhd:600` is already live and already correct, and it is load-bearing
for memory correctness rather than an optimisation: it suppresses `ROM_RD`
whenever CD RAM is selected, which is the only reason ROM and CD reads are
mutually exclusive and the single SDRAM read port is safe.

## 5g. P3 on hardware: the drive answers, twice wrongly

Built, flashed and run: `bios_3_0_jap.pce` as the cartridge, the Rondo cue in
`Disc (cue)`. Fit was 12,295 ALMs (66.5%), 227 M10K (74%), 26 DSP, slack
+0.095 ns.

The overlay confirmed both halves of the transport. `TRACKS 22` says the cue
parsed. `G0 O0 R0 L033 P62696E00` says the path chain rebuilt the name, opened
the bin into slot 101 and read from it, all three result codes zero.

The System Card boots its logo and stops on `JUST A MOMENT...`, which is where
it polls the drive. Two bugs, one of them the cause and one of them next in
line.

### The drive never said it had a disc

`dstate` came up `DS_NODISC` and had no transition out of it. Every
`TEST UNIT READY` therefore answered CHECK CONDITION with NOT READY / no disc,
which is a truthful report of the model's own state and a false report of the
machine. The System Card polls that before it does anything else.

The model was ported from `pcecdd.cpp`, where the tray is a real thing that
opens and closes and the host tells the drive when a disc arrives. Here the cue
*is* the disc: there is no insertion event to port, so the transition had no
obvious place to live and ended up with none. `cd_en` is already
`track_count != 0`, so reaching the run branch at all means a disc is loaded.

Fixed ahead of the case statement, so a command arriving in the same cycle
still overrides it: last assignment inside one always block takes effect.

### Every sector would have been off by one byte

`cd_fetch` registers its read, so `sec_data` trails `sec_addr` by a clock.
`S_PUSHSEC` captured on the same cycle it presented the address, and advanced
the address in the low phase rather than the strobe phase. The result: push #1
a stale byte, push #2 byte 0, and byte 2047 never sent at all.

This is the third time in this project a registered read has been consumed a
cycle early, after the P1 bridge read and the P2 TOC read. It is the same
mistake each time and it is invisible in the RTL, because nothing about
`data <= sec_data` looks wrong.

It would also have been near-impossible to diagnose from the outside. A sector
that is 2048 bytes long and entirely wrong is not a hang or a glitch; the
System Card would have loaded a corrupt boot sector and done something
arbitrary. It only surfaced because bug one was in front of it and forced a
line-by-line read.

Fixed by parking `sec_addr` on 0 while the fetch is in flight, which costs
nothing because the fetch takes thousands of clocks, and advancing in the
strobe phase so the address leads its byte by a full phase.

### The drive model got a diagnostic line

`dbg_state` was a 4-bit output wired to nothing. Replaced with a 26-character
overlay line:

    T22 C0007 O08 S5 D2 F0003

tracks, commands received, last opcode, sequencer state, drive state, sectors
fetched. Counters are snapshotted onto a 95 us divider before crossing to the
overlay clock, so a 16-bit count cannot tear mid-digit.

It sits below the two probes in the OSD priority and above the TOC line, and
carries the track count in its first field so displacing `TRACKS nn` loses
nothing. The TOC line's own `LAST` field is meaningless in P3 anyway: `rd_track`
belongs to `cd_host` now rather than being tied to the last track, so it shows
whichever entry the drive is pointing at, and at idle that is none.

The lesson from P1 and P2 was to measure rather than reason, and P3 was flashed
without a way to see inside the one new block. That was the actual error here;
the two bugs were ordinary.

## 5h. P3b on hardware: the drive works, the bytes do not

`T22 C0000 OFF S0 D1 F0000` at the ready prompt, `T22 C0006 O08 S0 D1 F0002`
after RUN. `D1` is DS_IDLE, so the drive reports a disc; six commands went
through, the last of them `READ6`; two sectors were fetched. The System Card
gets past the drive poll, reaches `PUSH RUN BUTTON!`, redraws as SUPER
CD-ROM(2), and stops on `LOAD ERROR!`.

So the protocol works end to end. What is wrong is the content.

### The addressing is right, checked against the disc

Rondo's track 1 is AUDIO and its data track is track 2, MODE1/**2048**, at
INDEX 01 00:48:65 = LBA 3665. The recurrence puts its base at 3665 * 2352 =
8,620,080, and that offset in the bin is Shift-JIS copyright text with
`PRODUCER`, `DIRECTOR` and `BIOS MAIN CODE, CD-PLAYER` in it. Subtracting the
225 sector PREGAP instead gives 8,090,880, which is audio. **The PREGAP
question is now settled against the disc rather than against the file length.**

The IPL is the next sector, absolute LBA 3666, carrying
`PC Engine CD-ROM SYSTEM` at 0x20 and a header of
`00 00 02 | 01 | 00 30 | 00 30`: load one sector from "2" to 0x3000 and execute
there. Data-track sector 2 is HuC6280 code with `JSR $E006` and `JSR $E05A` in
the first 0x50 bytes, both System Card entry points. So the "2" is relative to
the data track, the System Card adds the base it got from `GETDIRINFO`, and the
absolute LBA that reaches `READ6` is one this model maps correctly.

### What is left is alignment

Every data sector on this disc sits at 8,620,080 + n*2048, and 8,620,080 is 48
past a 512 byte boundary. The 2352 byte audio track in front of the data track
puts it there and it stays there for the whole track.

Every offset P0 and P1 ever read from was zero. Nothing in the APF material
this tree carries says whether a data slot read may begin at an arbitrary byte,
so this is not asserted as the cause. It is the only hypothesis left standing
once addressing is verified, and the fix is correct whether or not the
transport cared: `cd_fetch` now rounds down to a 512 byte boundary, asks for
2560 bytes instead of 2048, and starts the sector `skew` bytes in. Two more
M10K for the wider buffer, since 2560 rounds up to 4096.

### The overlay got four pages

One line could not carry it. The diagnostic now cycles four pages on its own
timer, about 1.6 s each, so none of them costs one of the fifteen APF menu
variables already spent:

    0  T22 C0006 O08 S0 D1 F0002    tracks, commands, opcode, state, drive, fetches
    1  H 00 DE DE DE 08 08          the last six opcodes, oldest first
    2  L00000E52 A00838830          last READ6 LBA, last fetch offset
    3  B00000201                    first four bytes of the last sector

Pages 2 and 3 are the ones that matter: they say what the System Card asked
for, where that landed in the bin, and whether the bytes that came back are the
bytes that are there. The whole line is registered on the 95 us divider rather
than each field separately, so a page change can never show half of one page
and half of the next.

## 5i. P3d on hardware: Rondo boots and plays

Konami logo, castle intro, title card, stage 1 with Richter on the wagon. The
CD path works end to end: TOC, open, seek, sector fetch, SCSI phasing.

In stage 1, 546 sectors in:

    T22 C0042 OD9 S0 D3 F0222
    H 08 08 08 08 D8 D9 E0
    L00000EFD A0088E830
    B00034000

`E0` is the whole transport verdict: not one fetch returned an error across the
boot and a stage of play.

### What actually fixed it

Two builds were spent on a fetcher that read a slot nothing had opened.
`path_start` was written only from bridge 0x414, the debug menu toggle. The
first P3 run happened to have the probe triggered by hand, which is why the
chain looked proven; the two runs after it did not, so slot 101 was never
opened and every 0x0180 failed into an untouched buffer. The drive dutifully
pushed 2048 zero bytes and the System Card said LOAD ERROR.

`F` counted up the whole time, because the command completed. It completed
unsuccessfully, and no diagnostic carried the result code. `E` exists now for
that reason: one field, and this would have been one run instead of two.

The 512 byte rounding in `cd_fetch` was needed as well. Both were real, which
is why fixing only the second one did not help.

### No audio, and exactly why

`D3` is DS_PLAY and the last opcodes are `D8 D9`, SAPSP and SAPEP. The game is
asking for CD-DA on nearly every screen and getting GOOD back from a model that
never asserts `audio_wr`. That is P4 as specified in 5e, not a defect: the
track table already carries what it needs, the drive already tracks the play
window and the modes, and nothing streams.

ADPCM is untouched and is P5. Rondo uses it for voice, so speech will still be
missing once CD-DA plays.

## 5j. P4 as built: the ring was never the problem

Rondo's CD audio plays. In stage 1, 18 seconds into a track:

    A0648 E0008 K2 W8R8 U0 N0
    Q 02 40 P1 T0012 B11A4

1608 reads over 18 seconds of playback is 89 chunks a second against the 86
Redbook needs. 4516 ms of transport time over those reads is 2.81 ms each,
which is what the throughput probe measures standalone. A 25% duty cycle is
exactly the work required to keep up, so the fetcher spends three quarters of
its time idle with the ring full.

### What cost four builds

Every frame was emitted backwards. The bridge writes big-endian into a word,
so byte 0 of the file arrives at bits [31:24] of the ring word. `cd_fetch`
already knew that and says so; `cd_audio` emitted [7:0] first, which swaps left
with right and byte-swaps both samples. Byte-swapped PCM is static.

The header of the module claimed the opposite in as many words: "the sectors
stream out verbatim, no swapping". Writing that down made it a settled fact
that never got checked, while four builds went looking upstream.

Two real bugs were found and fixed on the way, so the search was not wasted:

* **The fetcher deadlocked on the first SAPSP.** A restart abandoned an
  in-flight transport command between `cmd_ack` and `cmd_done`, throwing the
  completion away, and the next read waited for a `done` that had already
  gone. Restarts are deferred to `A_IDLE` now.
* **The audio read result was not connected at all**, so a failing read had no
  way to report itself.

### What the instrumentation was worth

It never pointed at the bug, and it is what found it. By establishing that the
rate, the read cost, the duty cycle and the ring contents were all correct, it
eliminated the transport entirely and left one place for the fault to be. The
sequence that worked, three times now, is to put the disputed quantity on
screen rather than reason about it: `G` proved the ring held the right bytes,
`A` and `E` killed the read-failure theory, `U` against `N` killed the Gray
crossing theory, and `T` with `B` killed the transport.

The one measurement that misled was a counter of seconds since reset read as
though it were seconds of playback. A rate needs both of its units checked.

## 6. Risks

* **Throughput.** The project risk, and the reason P0 comes first.
* **Reopen cost.** If `0x0192` is slow, a multi-bin redump set that switches
  files per track will stutter at track changes. A disc converted the §0 way is
  single-bin and never hits this, so it is a risk for other people's images
  rather than for the target. **Not retired: P1 proved `0x0192` works but did
  not time it.** The probe measures `0x0180` only, so a reopen cost would need
  its own measurement, and it only matters if multi-bin support is wanted.
* **SDRAM arbitration.** ROM reads and `CD_RAM` now share one controller, whose
  `raddr` is 25 bits. `docs/PLAN.md` §5 applies: check the slack report, not the
  exit code.
* **Firmware floor.** The `version_required` bump locks out older Pocket
  firmware. Users need telling.
* **Fit.** The CD block is priced in P0.5 rather than guessed at. MiSTer carries
  it plus SuperGrafx, but on a 5CSEBA6, not this core's 5CEBA4.

## 7. Open questions

1. Exact minimum APF `version_required` for `0x0180`, `0x0190`, `0x0192` and
   `deferload`.
1a. ~~May a data slot read start at an arbitrary byte?~~ **Not isolated.**
   `cd_fetch` rounds down to a 512 byte boundary and asks for the extra block,
   so the question no longer blocks anything. It was fixed in the same build as
   the unopened slot, so which of the two the LOAD ERROR belonged to was never
   separated, and it is not worth a build to find out.
2. ~~Does `0x0192` hold the file open across many `0x0180` reads?~~ **Answered
   2026-09-01: it holds.** P1's `R0` is a sector read out of the slot `0x0192`
   opened, issued as a separate command well after the open returned. What is
   still unmeasured is how long a reopen costs, which §6 now carries.
3. ~~Does slot 0 double as the System Card BIOS slot?~~ **Answered 2026-09-02:
   it does, and it costs no slot.** The System Card is a HuCard and goes to the
   same ROM space, so slot 0 takes either and carries `filename` plus
   `alternate_filenames` naming the five cards. Choosing a `.pce` fills the
   slot explicitly; choosing a `.cue` leaves it to the default. A finished cue
   load also restarts the machine, because the CPU can otherwise boot and read
   K[7] as no CD unit attached before the cue has arrived.
4. Does Super System Card RAM want to be nonvolatile alongside BRM, or is BRM
   in the existing save slot enough?
5. Which System Card does the core require? Rondo needs 3.0, and the US dump has
   a known bad variant that boots but fails some games.


## 5k. The drive lied about the music, and a stage load hung

Two symptoms from the same run. The opening cinematic played through with its
music. At the menu one sound played, cut off, and stopped. Starting the game
got as far as creating a save, then a black screen.

One cause is proven from the source, and one is not.

**Proven: a data read knocked the drive out of `DS_PLAY`.** `OP_READ6` set
`dstate <= DS_READ` and `S_WAITEND` returned it to `DS_IDLE` unconditionally.
The music does not stop for a data read, so from the first READ6 of a track
onwards `dstate` said idle while `aud_play` said playing. Everything that
answers from `dstate` was then wrong:

* `READSUBQ` reported audio status `03`, stopped, during playback.
* `subq_playing` went false with it, so `READSUBQ` reported the position of
  the last data sector instead of the position of the music.
* the end-of-region consumer was gated on `dstate == DS_PLAY`, so once a read
  had moved `dstate` the end of that track was never consumed at all and
  `aud_play` stayed high for the rest of the run.

A game that polls the drive while it loads a stage is reading all three. The
fix is that the audio state outlives a data read and a bus reset both:
`ds_resume` restores `DS_PLAY` or `DS_PAUSE`, and the end-of-region consumer
is gated on `aud_ended` alone.

The opening cinematic did not show this because nothing polls during it.

**Not proven: why the menu sound cut off.** It is one of two things and the
overlay now separates them. `Z` counts play regions that reached their end
offset. If `Z` steps at the cut, the region ended where row 5 says it ends,
and the question is whether that offset is right or whether the track should
have repeated. If `Z` does not step, something told the audio to stop, and the
mode bytes on row 4 say which command: `Q` is SAPSP's byte 1, `R` is SAPEP's.

Those were one register before, holding whichever command arrived last, which
is why the distinction was not available.

`SAPEP` still writes `aud_play` and `dstate` from its mode byte, which its own
comment says it should not do. That is deliberately left alone for one run:
changing it and measuring it together is how the byte order in 5j cost four
builds.

**P7a missed timing and the reason was not the logic.** Setup came back at
1.865 ns, better than P6c's 1.266, and the only failure was hold at -0.017 ns
on one domain with a TNS of -0.030.

The first guess was congestion, on the theory that turning the overlay on
through `CD_PROBE` had dragged both probe modules in with it. Splitting
`CD_DIAG` from `CD_PROBE` was worth doing anyway, but it is not what fixed
this and the numbers say so plainly:

| | ALMs | registers | hold |
|---|---|---|---|
| P7a, probes in | 14,769 | 14,388 | -0.017 ns |
| P7b, probes out | 14,810 | 14,116 | +0.008 ns |

The probes are 272 registers and no ALMs. Area went **up** without them. At
80% occupancy the hold slack in this domain is placement noise and both builds
sit inside it; P7b is not a fixed design, it is a luckier placement, and 8 ps
is not margin to rely on.

What the overlay actually costs is the overlay: close to 1,000 registers, 936
of them `line_r`, `cd_host`'s snapshot of the whole six-row block. With
`CD_DIAG = 0` none of it is built, which is the state a release ships in.

## 5l. The CPU stops asking, and two things could cause it

P7b on hardware. The `dstate` fix in 5k was correct and was not this bug: `Y`
reads 0000 in every frame, so Rondo never issues READSUBQ and was never waiting
on the status that fix repaired. In the whole run it sends three opcodes and no
others: `08`, `D8`, `D9`.

Starting a stage leaves a black screen for ever with ambience looping. There
`C` and `F` both stand still while the game is plainly still running, so the
CPU has stopped issuing SCSI commands and does not come back. Two things do
that and they look the same from outside:

* it is parked waiting on an interrupt. `cd.vhd` has exactly four sources,
  `CD_DTR`, `CD_DTD`, `ADPCM_END`, `ADPCM_HALF`, and an enable set with its
  flag clear says which.
* the SCSI bus never returned to bus free, so it cannot arbitrate to send
  anything. The phase lines say so directly.

P8 carries both out of `cd.vhd` on a debug word and puts them on row 5 as `I`,
with `ADPCM_LEN` on row 3 as `M`. **No behaviour changes.** Three times this
session a single overlay frame was read as a fault and was not one: the
SAPSP/SAPEP ordering, the title-screen `P1`, and a five second window with no
commands in it that turned out to be the cinematic loading normally. A frame is
an instant, and a counter standing still in one frame is not a stopped counter.

The audio side is measured and healthy: 437 reads in the five seconds between
two frames is 87 a second against the 86 CD-DA needs. Music stopping at the
title screen is `CDDA_FADE_VOL`, the CD unit's own fader, muting a stream that
is still being fed correctly.

`cdda_mode` is still one register written by both SAPSP and SAPEP, which is the
same defect as the shared CDB. It is deliberately left alone: SAPSP arrives
with byte 1 = 0x00 and SAPEP with 0x01, so separating them would make SAPSP
pause and nothing would start playback again, silencing music that currently
works. The character select and the title screen show identical mode bytes with
different intended outcomes, so the mode byte is not what selects them and
nothing here is understood well enough to change.

## 5m. The offsets are right, so the question is the content

P7b again, further in. The black screen is not permanent: the game reaches a
stage and draws it, corrupted. `DD` and `DA` both appear in the opcode history
now with `Y0001`, so Rondo does use READSUBQ and PAUSE, just later than any
earlier frame reached. The claim in 5l that it never polls was wrong.

The one number that repeats is `F0176`. Three frames 67 seconds apart hold it,
and so did two frames of the earlier run: **the game stops after exactly 374
sectors in two independent runs**, keeps issuing audio commands, and renders
whatever it has.

The addressing is not the fault, and this is checkable without hardware. The
cue recurrence puts LBA 0x0F5D at byte 0x008BE830, the overlay showed
`A008BE830`, and the bin holds `E5 E5 E5 E5` at that offset. Cue INDEX times
are file relative, so no 150 is subtracted; a first pass that subtracted it
disagreed with the disc and was wrong.

So P9 measures content. Row 3 becomes the last sector's first four bytes, a sum
of all 2048, and the READ6 count byte. With the LBA already on row 2 the same
sum can be computed from the bin on a PC. Agreement puts the sector out of this
module intact and moves the fault to the ADPCM DMA or the CPU side;
disagreement puts it in the fetch or the push.

## 5n. A readable overlay, kept for troubleshooting and never shipped

P9 verified the data path and closed two theories, and it also showed that the
measurement channel was the weakest part of the loop. The Pocket's screenshots
are 256 pixels wide and the overlay glyph is 5 pixels inside a 6 pixel cell.
Across one afternoon that produced `10C1` read for `10E1`, `7` for `8`, `B` for
`8`, and a `G` field that could not be read at all. Every misread cost a
hardware round trip, and two of them sent the investigation down a wrong path.

`cheat_osd` gains `DIAG_SCALE`. At 2 every cell is drawn 12 pixels wide and 16
scanlines tall, and each 26 character source row is drawn as two display rows
of 13. **Nothing that composes a row changes**: `cd_host`'s block, `cd_diag`
and every producer of a 156 bit line keep their format, because the split is
done where the character is fetched. 13 cells of 12 pixels is 156 pixels, and
with the 3 cell inset that is 192 of the 256 available. Twelve rows of 16 plus
a one row inset is 208 of 224 lines.

The cost is the whole cheat list: `MAX_LINES` is 0 in this mode. That is what
makes it a troubleshooting mode rather than a feature. A release sets
`CD_DIAG = 0`, which removes the block, the rows and `cd_host`'s counters
alike; `CD_DIAG_SCALE` then does not matter. Both switches live in `core_top`
next to `CD_PROBE`.

### What P9 established, before the mode existed

* **The data path is correct.** Two sectors verified byte for byte against the
  bin: LBA 0x0F5D at 0x008BE830 reading `E5 E5 E5 E5`, and the offset the
  overlay reported at the freeze, 0x00980830, reading `00 03 40 00`. Position
  and content both.
* **The CPU is not waiting on an interrupt.** `I827F` has `IRQ_N` high with no
  enable and flag pair armed together.
* **The SCSI bus is free.** The low seven bits of `I` read 0x7F. The CPU could
  issue a command and does not.

So 5l's two candidates are both dead. What is left, and unexplained: at the
freeze the last opcode is `D8` with `X` still `FFFFFFFF`, meaning SAPSP was
answered and **no SAPEP followed**, where every working frame has `D9` next.

One regularity is noted and explicitly not concluded from: both audio starts
resolve to exactly 375 sectors, five seconds, into their track, on two
different tracks. It may be a pre-roll the game intends.

### The hold failures were never ours, and AUTO FIT is why

P10 and P10b both missed hold by about 15 ps, so instead of a third seed the
compiled design was re-analysed on the runner with `report_timing -hold`, no
recompile. Every violating path is the same structure, and it is inherited:

    HUC6270:VDC0 | SPR_LINE_D[0][1..3]
      -> dpram:SPR_LINE_BUF0 ... porta_datain_reg[1..3]
    Clock Skew 0.413 ns    Data Delay 0.401 to 0.412 ns

The VDC's sprite line buffer. A register into an M10K where clock skew just
exceeds data delay, so it fails hold by picoseconds and flips sign with
placement. That one structure accounts for the whole day: -0.017, +0.008,
+0.104, +0.100, -0.017, -0.012, in builds whose contents had nothing to do with
it. Nothing added by the CD work, the debug word or the overlay ever touched
that path, and the causes given for those numbers at the time were invented.

`FITTER_EFFORT="STANDARD FIT"` fixes it:

| build | fitter | ALMs | setup | hold | compile |
|---|---|---|---|---|---|
| p10  | AUTO FIT      | 15,060 | 1.536 | **-0.017** | 667 s |
| p10b | AUTO FIT seed 2 | 15,036 | 1.548 | **-0.012** | 667 s |
| p10c | STANDARD FIT  | 15,048 | 2.432 | **+0.117** | 707 s |

Same area, 40 seconds more compile, and the best margins of the session on both
setup and hold. AUTO FIT lowers effort once it believes timing is achievable,
which leaves a marginal path marginal; `tools/podman/build.sh` already carries
the switch and says so in its own comment.

**Worth deciding:** whether STANDARD FIT becomes the default for this project
rather than an env var. It would end the reseeding lottery, and the cost is 40
seconds a build. Left as a question because the qsf is shared with upstream and
the baseline ALM number should keep coming from an unmodified run.

## 5o. Byte perfect sectors, and the game still lands in the wrong place

The doubled overlay paid for itself on the first frame. Every field read
cleanly, and `L000010E1` settled that the LBA was 0x10E1 all along: the `10C1`
that sent an earlier pass chasing a phantom offset error was a misread, not a
fault.

**The sector is delivered byte perfect.** `G0651` is exactly the 16 bit sum of
the 2048 bytes at 0x00980830 computed from the bin, and `B00034000` matches its
first four. Not just the head: the whole sector. Fetch, offset arithmetic and
push are all correct, end to end, and content corruption is ruled out.

`F0176` also stops being a signal. It reads 374 in every run including ones
that reach a menu, so 374 sectors is simply what Rondo reads. It was never the
stall it looked like.

What is actually wrong: the menu boots into a **malformed death screen**. Right
bytes, wrong destination. With content ruled out, the way left to corrupt a
load is to deliver fewer sectors than the READ6 asked for. The game fills part
of a buffer, is answered GOOD, believes it is loaded, and jumps into whatever
the hole leaves. `N20` says the reads are 32 sectors each and nothing has ever
compared what was asked for with what arrived.

So P11 adds `R`, every sector every READ6 has requested, to sit beside `F`,
every sector delivered. If they differ, that is the bug and its size. `V`
counts SCSI RST aborts as the obvious way a transfer gets cut short.

One more thing changed with no functional change behind it: P9 and P10 were
instrumentation only, yet the run now gets further than P7b did. **The failure
is not deterministic**, which is worth remembering before any fix is called
proven by a single good run.

`I8A13` at that instant has the bus in STATUS phase with REQ asserted and ACK
not, where an earlier frame read `I827F`, bus free. Both are single instants
and neither is yet evidence of anything.

## 5p. The phase break between sectors is load bearing

A real drive answers a 32 sector READ6 in one continuous data in phase. This
model answers in 32, because `SCSI.vhd` ends the phase the moment its FIFO runs
dry and the next sector takes 2.81 ms to arrive from the APF. That gap looked
like the way the ADPCM DMA gets fed game data: it takes bytes from any data in
phase while `ADPCM_DMA_EN` is set, and the game clears `DMA_EN` on its own
schedule.

Chaining the sectors to hold one phase open **stopped the core booting**, twice.

The first attempt over-fetched: `F` ran ahead of `R`, 2303 sectors delivered
against 2195 asked for. `cd_fetch` is a four phase handshake and `S_FETCH`
completed on a bare `fetch_done` without checking it had asked. `done` clears
only after `req` drops, through two three deep synchronisers across the 74 and
43 MHz boundary, about 140 ns; re-entering the state 93 ns later consumed the
previous sector's completion. That was a latent hazard the old millisecond wait
in `S_WAITEND` made unreachable, and qualifying it with `fetch_req` is kept.

The second attempt got the counts right and still would not boot: the System
Card re-read the same few sectors for ever, `L` walking 0F7E to 0F7C while `C`
and `F` climbed. `CD_DTR` in `cd.vhd` is how the CPU learns a sector finished,
and at byte 2048 it drops for exactly one clock before the arming branch
re-asserts it, because the phase conditions still hold. Across a phase break it
stays low for milliseconds. Inside a continuous phase the CPU cannot see it.

So the per-sector phase break is not an artifact, it is how sector completion is
signalled here, and the chaining is reverted. **The ADPCM theory is untested,
not disproven**: this was the route to testing it and the route is closed.

Kept from the attempt, both real:

* `S_FETCH` completes only on `fetch_req && fetch_done`.
* `SCSI.vhd` exports `FIFO_FULL` and `S_PUSHSEC` stalls on it. The push side had
  no flow control at all and `SCSI.vhd` drops a byte written to a full FIFO
  without saying so. Nothing outside could see the flag.

## 5q. Count the bytes the DMA takes, since the phase cannot be held open

5p closed the route that would have tested the ADPCM theory by construction. It
does not need that route. The theory is that the ADPCM DMA takes bytes out of a
data in phase that was not its own, and the DMA has a single point of intake:
one branch in `cd.vhd` that latches `SCSI_DBO` when `ADPCM_DMA_EN` or
`ADPCM_DMA_RUN` is set and the bus is in data in. Counting there answers it.

Two counters, both 16 bit, both reset only by `RST_N`:

* `DMA_BYTE_CNT`, every byte the DMA lifted off the bus.
* `DMA_EN_BYTE_CNT`, the subset lifted with `ADPCM_DMA_RUN` clear.

The split is the whole point. `DMA_RUN` clears itself at 2048 bytes, so bytes
taken under it are a sector the game asked for and got. `DMA_EN` does not clear
itself, so bytes taken under it alone are the DMA still holding its hand out
after its sector arrived, and the next data in phase is whatever the game reads
next. `W` climbing while `O` reads 08 is the answer; `W` at 0000 through a
freeze retires the theory for good.

`CD_DBG` widens to 48 bits to carry both without giving up `ADPCM_CTRL` and the
flags, and row 3 becomes `U W K I R`. Off it come `M` (`ADPCM_LEN`), `N` (reads
with a zero sector count) and `S` (the offset SAPSP resolved to), each having
answered its question.

## 5r. p18 retires the DMA theory and exposes the shared-bus race

p18 on hardware, in the latest four PC Engine screenshots. `U` and `W` remain
`0000` throughout. The last two diagnostic frames are byte-identical four
seconds apart in the failed state, so this is not another transient read. The
ADPCM DMA took no bytes at all in the captured failure and the theory in 5q is
retired.

The failure remains nondeterministic. One launch produced a black screen while
the cinematic audio played. The captured launch produced a mismatched screen
with appropriate audio looping. It ends with `F0176` and `R0176` again: every
sector requested was delivered.

There is a source-visible collision after the point every existing sector
checksum observes. `cd_audio` asserts `aud_req` on odd `fstep` values and, at
`fstep == 7`, clears `aud_busy` in that same clock. One clock later `cd_host`
sees the registered tail `aud_req` with `aud_busy` already clear. If a SCSI
push is on its strobe half then both happen:

* the push state asserts `data_wr`, advances `sec_addr` and adds the intended
  `sec_data` to the diagnostic checksum;
* the assignment after the sequencer replaces shared `data` with `aud_data`
  and asserts `audio_wr` from the same request.

The SCSI FIFO therefore receives an audio byte in place of a sector byte. No
byte is dropped, so the CPU count remains right. The checksum is computed from
`sec_data` before the shared-bus override, so it remains right. Requested and
delivered sector counts remain right. Whether the replacement lands depends
on the relative audio and SCSI push phase, matching the run-to-run variation.

p19 makes the audio hold condition `aud_busy || aud_req` for both response and
sector pushes. Hardware counters record tail cycles that would previously have
collided and any remaining `data_wr && audio_wr` overlap. The latter must stay
zero; the former moving proves the fixed case was exercised.

## 5s. p19 excludes the shared-bus race; p20 shows ordering is insufficient

p19 reached normal stage play on hardware. Three diagnostic frames during the
horse scene all show `U0158 W0000`: 344 registered audio tail requests held off
a SCSI byte, and no cycle asserted both write strobes. The counter that proves
the old collision opportunity moved, the counter that proves exclusion stayed
zero, and the following screenshots show the boss and live stage gameplay.
This is positive evidence for the arbitration fix, not merely an uneventful
run.

The first p19 launch exposed a separate problem. It reported no saved games,
then a newly created record appeared at 32 percent and the game started in a
corrupted state. After a Pocket reboot the malformed record was deleted, a new
one was created, and the game played normally.

The card identifies the save-selection fault. The prior CD run had created
`Saves/pce/common/bios_3_0_jap.sav`; p19 created `Saves/.sav`. Both are 2048
bytes and contain a Rondo backup-RAM record. APF was deriving the nonvolatile
name from the primary manifest entry, so a manually selected BIOS named one
save and a default BIOS left the other name empty. The official APF definition
says the primary slot is the first entry in `data.json`. Mazamars312's CD-only
manifest puts its required cue first, which this combined core cannot copy
without making HuCard naming use an absent cue.

This core also launches HuCards, so p20 tried the combined ordering
`0, 100, 1`: Cartridge or System Card, cue, then Save. That was based on the
incorrect assumption that APF used the nearest selected media slot preceding
Save. Save moved from manifest index 1 to index 2 and the size datatable write
moved with it, but the later hardware test disproved the naming assumption.

p20 hardware verification is filename-first, then gameplay:

1. Launch Rondo from its cue and verify APF uses
   `Saves/pce/common/Castlevania - Rondo of Blood.sav`, never `Saves/.sav` or a
   BIOS-named save.
2. Create or alter a record, quit the core, relaunch it, then reboot the Pocket
   and relaunch once more. The same record must survive both boundaries.
3. Launch a HuCard with an existing save and verify its game-named save still
   loads. The shared manifest must not fix CD saves by regressing HuCards.
4. Repeat the CD boot to stage play three times. Every run must reach gameplay,
   `U` must move, and `W` must remain `0000`.

p20 was built on kira LXC 151 with `STANDARD FIT` and installed on the card.
The full fit took 1363 seconds, used 14,952 of 18,480 ALMs, and passed every
timing analysis. Worst setup slack is `+2.297 ns`; worst hold slack is
`+0.098 ns`. The packaged `pce.rev` MD5 is
`ac08484a444b6bae18520f65f0ae8a00`, verified equal on the card. The packaged
and deployed `data.json` SHA256 is
`af25fd012cf074dc28614e190c4beb27685ebf51bbb8773de6c4346669f7c732`.

The good p19 backup-RAM image was preserved locally under ignored build
evidence and left on the card as root `Saves/.sav`. p20 loaded it despite the
manifest reorder: the save screen showed the existing `BRO` record at 4
percent, normal stage play followed, and APF updated that same file on exit.
The before and after images differ at exactly one byte, offset `0xBB`, from
`00` to `01`. Save loading and persistence therefore pass across a core
replacement.

No cue-named save was created in the first run. Because the existing root
binding was reused, that run alone could not distinguish reuse from ineffective
ordering. The later fresh test answers the question below.

Four p20 screenshots were copied and hash-verified under ignored
`build/evidence/p20/`, then removed from the card at the user's request. The
final overlay shows `F0176 R0176 U0144 W0000`; every requested sector arrived,
324 old collision opportunities were excluded, and no actual write overlap
occurred. The intervening frame shows normal live stage gameplay.

The final fresh-name test is complete. After verifying it against the local p20
copy, root `Saves/.sav` was moved recoverably on the card to
`Saves/.sav.p20-pre-fresh-test`. Its SHA256 remains
`b0114f4883532e6c83f2d0e83bc532d9cda3e9f6583c639809ca46c39f7dcd7e`.
On the next launch the old record was absent and Rondo required both opening
cartoons. The user completed stage 0 and began stage 1 without a fault. The
captured overlay shows `U02BF W0000`, another exercised pass of the p19
arbitration fix.

APF created a fresh 2048-byte root `Saves/.sav`, not a cue-named file. Its
SHA256 is
`e0a82c5310f69e5d73d73452e143d45fa3c6090f66604b55d210368399eabcff`.
It begins with `HUBM`, contains `DRACULA X`, and differs from the preserved old
image at 46 byte positions. Reset was pressed while trying to quit, but the new
file was written at 09:25:24 and is structurally recognizable. A relaunch is
still required to prove that it loads.

The manifest order `0, 100, 1` is therefore not a working CD save-naming fix
for this combined HuCard and CD core. p20 must not be released as though it
provides cue-derived saves. Any next implementation changes the tested source
and requires a new timing-clean build, card install and hardware verification.
The exact screenshots and both save images are cataloged under ignored
`build/evidence/p20/fresh-save/`.

After that catalog was verified, the wrong fresh root `.sav` and both
follow-up screenshots were removed from the card at the user's request. The
old image remains there as `Saves/.sav.p20-pre-fresh-test`, and all removed
files remain in ignored local evidence. The card is mounted for the resumed
session.

The next design is an explicit runtime binding rather than another ordering
guess. Once the cue path is known, target command `0x0192` can open or create
the corresponding path under `Saves/pce/common/` in save slot 1. A following
`0x0180` can load it through the existing save bridge before CD reset is
released. HuCards keep their current automatic slot-0 naming because the
rebind runs only after a cue is parsed.

## 5t. p21 binds the save slot from the runtime cue path

p21 implements the explicit route in functional commit `b86a38b`. Manifest
order returns to `0, 1, 2, 100, 101`, so automatic nonvolatile naming remains
adjacent to the primary HuCard slot. CD launch no longer depends on manifest
ordering for its save.

After the selected cue path is read and the bin is opened, `dataslot_path.sv`
rewrites `/Assets/.../name.cue` as `/Saves/.../name.sav` in the path buffer. It
opens that path into slot 1 with create but not resize. Result 1 identifies a
new zero-length file, which is then reopened with resize-only flags and a size
of 2048 bytes. Existing files never take the resize path. Finally, `0x0180`
loads slot 1 into the existing save bridge window. `valid`, and therefore
`bin_ready`, is withheld until that read succeeds. `core_top.v` keeps CD reset
asserted while a cue is loaded but `bin_ready` is false, preventing the System
Card from observing stale root-save contents during the rebind.

The three trailing path diagnostics now begin with `S` and show the save open
and read results. A fresh successful path is `S10`; an existing successful
path is `S00`. Any other result keeps CD reset asserted and is a hard failure,
not a partial launch.

Built on sisko from an isolated detached checkout with Quartus Lite 25.1 and
`STANDARD FIT`, 16 processors. The fit took 831 seconds and used 15,021 ALMs.
Every analysis passed: worst setup `+2.408 ns`, hold `+0.072 ns`, recovery
`+12.012 ns`, removal `+0.059 ns`, minimum pulse width `+0.831 ns`. The raw
RBF SHA256 is
`ccd397d2b80022ce9cba62859b7c43162f4a81e519ddf9fde3f9d7a1dff14992`.
The locally packaged `pce.rev` MD5 is
`37589416822862010413a4af78ab318a`; packaged `data.json` SHA256 is
`238bd3495b79c60345262382558a4541503080d6495ecdc546925194d81d9f19`.

Hardware answers the writeback question: pass. The installed p21 package
matched the build hashes. A fresh launch created
`Saves/pce/common/Castlevania - Rondo of Blood.sav` at 2048 bytes while root
`Saves/.sav` remained absent. Its first captured SHA256 was
`2de0d66eee36dade46201567821d98ae5fa5885893e2d16fd0bda899307b422f`.
After the user completed stage 0, exited, and relaunched, Rondo loaded the
record at 4 percent. The post-stage-0 file SHA256 was
`8128add46b7934a761df2f76fd200540d72e31805d96ffed12e40c919318bb3a`.
Both card states were copied and byte-verified locally. Runtime binding now has
positive hardware evidence for create, writeback, and reload.

One save gate remains: run a HuCard with an established save to prove the
restored manifest ordering preserves automatic HuCard save naming and loading.
