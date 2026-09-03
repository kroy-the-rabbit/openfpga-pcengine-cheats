# CD handoff, 2026-09-03 (evening)

Read this, then `docs/CD-PLAN.md`, 5k to 5q for the last two sessions.

## Where it stands

**Rondo boots, plays, and reaches a stage** from cue plus bin on hardware with
no host processor. It does not survive play. The failure varies run to run:

* black screen with a sound effect looping, usually the galloping horse
* the menu booting into a malformed death screen
* a hard freeze with random sound effects

| | |
|---|---|
| branch | `cd-streaming`, p18 based on `92b51c0` |
| working tree | p18 source and its hardware result are in this commit |
| on the card | p18, `pce.rev` md5 `4928e642377f3a9b5e575ab58d0d104f` |
| build | `FITTER_EFFORT="STANDARD FIT"`, eight for eight on timing |
| worktree | `worktrees/p5` on `cd-adpcm`, nothing committed |

p18 is built, flashed, timing-clean and tested on hardware. The latest batch
is copied off the removable card under ignored `build/evidence/p18/`.

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
must make audio ownership include `aud_req`, not only `aud_busy`, and count
both avoided opportunities and any actual strobe overlap.

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

1. The freeze and malformed load during play. p19 tests the shared-data-bus
   collision found after p18 retired the ADPCM theory.
2. Random or looping sound effects. The p18 capture played appropriate audio;
   repeatability still has to be established after the data-bus fix.
3. Two of three SAPSP address forms unexercised.
4. Eight audio reads fail at startup with APF result 2, unexplained.
5. **Cheats have never been run against a CD game.** The point of the fork.
   `Castlevania - Rondo of Blood.cht` is on the card, five titles, six pokes.
6. Whether `STANDARD FIT` should be the project default rather than an env var.

## Things that will bite

* **Screenshots come off the card**, `/run/media/kroy/pocket/Memories/
  Screenshots/`. Nowhere else. Check the mount before concluding anything.
* **Find the card by mount point, not `/dev/sdX`.** The letter moves between
  insertions. `findmnt -rn -o SOURCE /run/media/kroy/pocket`.
* **Merge onto the card, never `--delete`.** Saves, cheats, discs and dumps
  live there. Unmount after writing.
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

Builds run on the runner `root@10.50.1.246`, not locally and not in CI. There
is no committed wrapper; the one used for p18 lived in a session scratch dir
and is gone. It did four things:

1. `rsync -a --exclude build/ --exclude .git/ ./ RUNNER:/root/pocket-pcengine/`
2. `ssh RUNNER 'cd /root/pocket-pcengine && FITTER_EFFORT="STANDARD FIT"
   BUILD_NAME=p19 tools/podman/build.sh'`, then `tools/podman/report.sh`
3. rsync `build/p19/{report.txt,elapsed}` and
   `build/p19/work/projects/output_files/pce_pocket.rbf` back
4. if `report.txt` has no `^Slack : -`, `BUILD_NAME=p19 tools/podman/dist.sh`

The runner has no `jq`, so `report.sh` and `dist.sh` print a `jq: command not
found` on the packaging step. That is not a build failure. Roughly 720 s.

Output lands in `build/p19/dist`. rsync that onto the card without `--delete`,
verify the `pce.rev` md5 against the source, unmount. **Committing this wrapper
into `tools/` is worth doing;** it has been retyped every session.
