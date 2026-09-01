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
| **P0.5** | One build with `EN => '1'` and nothing else, to price the CD block. | ALM and M10K delta recorded in `docs/BASELINE.md`. |
| **P1** | `0x0190` and `0x0192`, plus the path struct RAM. Prove it by opening a bin the cue names and reading its first sector. | **Done 2026-09-01, passed on hardware.** `G0 O0 R0 L033 P62696E00`. See §5b. |
| **P2** | `cd_toc.sv`, the cue parser, modeled on `cheat_loader.sv`. TOC in BRAM: per track, start LBA, sector size, type, file index, byte offset. | A Rondo cue parses to the right track count and start times. |
| **P3** | `cd_host.sv`: answers `CD_COMM` with `CD_STAT`/`CD_MSG`/`CD_DOUT`, LBA to offset, sector fetch, `CD_DATA`/`CD_DATA_WR`/`CD_DATA_END`. Data track only, no audio. Uncomment `main.sv`, wire the SDRAM `CD_RAM` path, drive `CD_EN` from a loaded cue. | The System Card reaches its menu and a game reads sector 0. |
| **P4** | CD-DA: prefetch ring, `CD_AUDIO_WR` at rate, SAPSP, SAPEP, PAUSE, READSUBQ. | Rondo's intro plays in sync. |
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

**Byte offsets are a recurrence, not a multiply.** Per track the parser needs
the `INDEX 01` time, the `PREGAP` if any, and the sector size from the `TRACK`
line. Then, with L for start LBA and S for sector size:

    base(k) = base(k-1) + (L(k) - pregap(k) - L(k-1)) * S(k-1)

and a sector inside track k sits at `base(k) + (LBA - L(k)) * S(k)`. The
`- pregap(k)` term is the one that matters: a pregap occupies disc addresses
and no file bytes, so leaving it out shifts every track after the first by its
length. Rondo's track 2 has a 225 sector pregap, which is 529,200 bytes at
2352, and the failure would present as a disc that mounts and then reads
garbage.

Techniques worth taking verbatim from `cheat_loader`: `S_SKIP` as the
catch-all, so `REM`, `CATALOG`, `PERFORMER`, `ISRC` and `FLAGS` cost nothing;
whole-length keyword matching against a `key_ok` vector, since prefix matching
is what made it read the wrong field and look like it worked; and a structural
bound, one `room` term in the commit predicate, so no cue can overflow the
table however malformed it is.

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
2. ~~Does `0x0192` hold the file open across many `0x0180` reads?~~ **Answered
   2026-09-01: it holds.** P1's `R0` is a sector read out of the slot `0x0192`
   opened, issued as a separate command well after the open returned. What is
   still unmeasured is how long a reopen costs, which §6 now carries.
3. Does slot 0 double as the System Card BIOS slot? The System Card is a 256KB
   HuCard image going to the same SDRAM ROM space, which is how MiSTer treats
   `cd_bios.rom`. A separate named slot is friendlier but costs a slot.
4. Does Super System Card RAM want to be nonvolatile alongside BRM, or is BRM
   in the existing save slot enough?
5. Which System Card does the core require? Rondo needs 3.0, and the US dump has
   a known bad variant that boots but fails some games.
