# CD handoff, 2026-09-03 (night)

Read this, then `docs/CD-PLAN.md`, 5k to 5s for the last sessions.

## Where it stands

**Rondo boots and reaches live stage play** from cue plus bin on hardware with
no host processor. p19 fixed the phase-dependent shared data-bus corruption
found after p18, and its hardware counters prove that the fixed collision case
was exercised. Repeatability across cold launches is not established yet.

| | |
|---|---|
| branch | `cd-streaming`, p18 committed as `46f9a34` |
| working tree | p19 arbitration fix plus p20 save ordering, docs and regression check, uncommitted |
| on the card | p20, `pce.rev` MD5 `ac08484a444b6bae18520f65f0ae8a00` |
| build | kira LXC 151, `STANDARD FIT`, setup `+2.297 ns`, hold `+0.098 ns` |
| worktree | `worktrees/p5` on `cd-adpcm`, nothing committed |

p19 screenshots and the two candidate CD saves are copied off the removable
card under ignored `build/evidence/p19/`. p20 is built, timing-clean, packaged,
installed and hash-verified. It now needs the hardware test below.

## What p19 found

The three diagnostic screenshots all show `U0158 W0000`. `U` counts registered
audio tail requests that held off a SCSI byte which the old arbitration would
have pushed. `W` counts actual `data_wr && audio_wr` overlap. The avoided case
occurred 344 times, no overlap remained, and the next screenshots show normal
boss and stage gameplay. The p19 arbitration fix is positively exercised.

The first p19 launch still behaved strangely: it saw no old record, a newly
created record claimed 32 percent completion, and game startup was corrupted.
After reboot, deleting that record and creating another led to normal play.
The card explains the missing record separately. The old CD save is
`Saves/pce/common/bios_3_0_jap.sav`; the latest is `Saves/.sav`. APF was naming
the nonvolatile slot before it encountered the selected cue.

p20 reorders the first manifest slots to `0, 100, 1`: Cartridge or System Card,
cue, Save. This preserves HuCard naming and makes the cue name a CD save. The
save-size datatable write moved from manifest index 1 to index 2, and the
manifest checker enforces both facts. The good root `.sav` was not migrated,
so the test cannot pass accidentally against an old file.

## What p18 found

The one open theory for the freeze and the random samples: the ADPCM DMA takes
bytes out of a data in phase that was not its own. It consumes from any data in
phase while `ADPCM_DMA_EN` is set, `DMA_RUN` self clears after 2048 bytes and
`DMA_EN` does not, so a game that leaves `DMA_EN` set feeds whatever the CPU
reads next into ADPCM RAM. That plays game data as samples and starves the CPU
of its sector.

p18 counts at the DMA's single point of intake in `cd.vhd`, the branch that
latches `SCSI_DBO` when `DMA_EN or DMA_RUN` and the bus is in data in:

* `DMA_BYTE_CNT`, every byte taken. On the overlay as `U`.
* `DMA_EN_BYTE_CNT`, the subset taken with `DMA_RUN` clear. On screen as `W`.

`CD_DBG` widened 32 to 48 bits to carry both. Row 3 is now `U W K I R`; `M`
(`ADPCM_LEN`), `N` (zero count reads) and `S` (SAPSP's resolved offset) came
off, each having answered its question.

`U` and `W` both remain `0000` in every diagnostic frame, including while
`O08` is active and in two byte-identical failed frames four seconds apart.
The ADPCM DMA took no bytes at all in the captured failure, much less bytes
under `DMA_EN` alone. **The theory is retired.**

The latest run remains nondeterministic. One launch reached a black screen
while the cinematic audio played. The captured launch reached a mismatched
screen with appropriate audio looping. Its final state still has `F0176` and
`R0176`, so every requested sector arrived.

The next source-visible fault is the shared `CD_DATA` arbitration. On the last
byte of an audio frame, `cd_audio` asserts `aud_req` and clears `aud_busy` in
the same clock. On the following clock `cd_host` can see `aud_busy = 0`, push a
sector byte and advance its checksum/address, then let the later `aud_req`
assignment replace the shared bus byte with audio. The CPU still takes one
byte and every upstream diagnostic still passes; only its value is wrong.
That phase-dependent substitution fits the nondeterministic corruption. p19
now makes audio ownership include `aud_req`, not only `aud_busy`, and its
hardware counters show 344 avoided opportunities with no remaining overlap.

## Established, so nobody chases it again

All measured on hardware:

* Sectors arrive **byte perfect** at the **right offsets**. `G0651` was the 16
  bit sum of the 2048 bytes at 0x00980830, computed independently from the bin.
* **Every sector asked for is delivered.** `R` equals `F`.
* **The CPU takes all 65536 bytes** of a 32 sector read. `D0000`.
* **The ADPCM DMA is not stealing data.** p18 held both `U` and `W` at zero
  through the captured failure.
* **No interrupt is ever armed** and **the bus is never stuck.** A healthy
  frame shows the same SCSI phase as a frozen one.
* `F0176` is **not** a stall. 374 sectors is what Rondo reads.
* Timing failures are **not ours**. The path is inherited, `HUC6270:VDC0 |
  SPR_LINE_D` into the sprite line buffer. `STANDARD FIT` fixes it, seeds are a
  lottery.
* **PREGAP belongs in the LBA, not the byte offset**, commit `a324173`. Three
  commands, three exact hits.

## Still open

1. p20 save naming and persistence across both core exit and Pocket reboot.
2. Three clean CD launches to stage play with `U` moving and `W=0000` in each.
3. HuCard save naming after the shared manifest reorder.
4. Random or looping sound effects need repeatability after the data-bus fix.
5. Two of three SAPSP address forms remain unexercised.
6. Eight audio reads fail at startup with APF result 2, unexplained.
7. **Cheats have never been run against a CD game.** The point of the fork.
   `Castlevania - Rondo of Blood.cht` is on the card, five titles, six pokes.
8. Whether `STANDARD FIT` should be the project default rather than an env var.

## p20 hardware test

1. Launch Rondo once. It is expected not to see root `Saves/.sav`.
2. Create a fresh record, quit the core, and check that the card created
   `Saves/pce/common/Castlevania - Rondo of Blood.sav`. A new root `.sav` or a
   BIOS-named save fails p20 immediately.
3. Relaunch the core and verify the same record, then reboot the Pocket and
   verify it once more.
4. Launch one HuCard with a known save and confirm its game-named save loads.
5. Repeat the Rondo launch to stage play three times. Capture `U` and `W` each
   time. `U` must be nonzero and `W` must stay `0000`.

## Things that will bite

* **Screenshots come off the card**, `/run/media/kroy/pocket/Memories/
  Screenshots/`. Nowhere else. Check the mount before concluding anything.
* **Find the card by mount point, not `/dev/sdX`.** The letter moves between
  insertions. `findmnt -rn -o SOURCE /run/media/kroy/pocket`.
* **Merge onto the card, never `--delete`.** Saves, cheats, discs and dumps
  live there. Unmount only when told.
* **A single overlay frame is worth nothing.** Four times across these sessions
  a transient was read as a fault.
* **Do not narrate timing slack.** `report.sh` prints per clock worst slack and
  nothing else. It is a pass or fail gate, there is no path in it.
* **`cd.vhd` and `SCSI.vhd` are inherited and CRLF.** Write them in binary mode
  or the diff becomes the whole file.
* **Do not try to hold one data in phase open across a multi sector read.** It
  was tried twice and 5p records why: `CD_DTR` is how the CPU learns a sector
  finished, and inside a continuous phase it is low for one clock instead of
  milliseconds. The per sector phase break is load bearing.
* **`err` is sticky, `F` `W` `R` are counters.** Never read a sticky field as a
  rate.
* **Byte 0 of the file is bits [31:24] of a bridge word.**
* **Quartus exits 0 on a design that misses timing.** `report.sh` is the gate.
* **Read `build/<name>/elapsed`** rather than estimating how long a build took.

## Build and flash

Builds run on a remote runner, never locally and never in CI. p20 used kira
LXC 151 directly at `root@10.50.1.245`; all six public SSH keys published by
the `kroy-the-rabbit` GitHub account are installed there. `jq` and `ripgrep`
were also installed, so the runner now completes the manifest checks and
packaging instead of ending with the old `jq` return code 127.

The p20 source was a tracked-file archive of the live worktree, including the
uncommitted p19 and p20 changes, extracted at
`/root/pocket-pcengine-p20-20260903`. The exact source hashes recorded in the
build are:

* `rtl/pce/cd_host.sv`: `07b545312fe9b94bb66d79d94971e82818756cb031f5a3c51fcff0f1d55bfc5b`
* `target/pocket/core_top.v`: `f894bb2190d186b0ec5b46bbb15ce350de0deb395bbabfa117bede8bccf8ce5e`
* `pkg/Cores/kroy.PCE/data.json`: `af25fd012cf074dc28614e190c4beb27685ebf51bbb8773de6c4346669f7c732`

The build command was `FITTER_EFFORT="STANDARD FIT" NPROC=16 BUILD_NAME=p20
tools/podman/build.sh`. The runner output is under that checkout's
`build/p20/`; the pulled and locally packaged output is `build/p20/dist/`.
Merge that directory onto the mounted card without `--delete`, run `sync`, and
verify both `pce.rev` and `data.json` in place. The sandbox can misreport the
card as read-only, so request elevation outside the sandbox for the copy. Do
not remount the card and do not unmount it unless told.
