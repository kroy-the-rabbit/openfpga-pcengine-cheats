# CD handoff, 2026-09-03

Read this first, then `docs/CD-PLAN.md` for the phase plan and 5k to 5p for
this session.

## Where it stands

**Rondo boots, plays, and reaches a stage.** Cue plus bin, on hardware, no host
processor. It renders real gameplay: Richter, the carriage, Death, the fire.

It does not survive play. The failure varies run to run and is not
deterministic:

* black screen with a sound effect looping, usually the galloping horse
* the menu booting into a malformed death screen
* a hard freeze with random sound effects

| | |
|---|---|
| branch | `cd-streaming` |
| on the card | p17, verified `7ac2cfa8` |
| build | `FITTER_EFFORT="STANDARD FIT"`, seven for seven on timing |
| worktree | `worktrees/p5` on `cd-adpcm`, nothing committed |

## Fixed today

* **PREGAP belongs in the LBA, not the byte offset.** `cd_toc` used one number
  for both. Pregap sectors are absent from the bin, so `base` is right to skip
  them, and the disc numbers them, so `lba` must not. Every track was reported
  225 sectors early from track 2 and 375 from track 3. Verified on hardware,
  three commands, three exact hits. Commit `a324173`.
* **A data read no longer knocks the drive out of `DS_PLAY`.** Commit `d5c7de4`.
* **`S_FETCH` completes only on `fetch_req && fetch_done`.** `cd_fetch` is a
  four phase handshake and `done` outlives the request by about 140 ns.
* **`SCSI.vhd` exports `FIFO_FULL` and the push side stalls on it.** There was
  no flow control at all and a byte written to a full FIFO is dropped silently.
* **A diagnostic overlay that survives a screenshot**, `CD_DIAG_SCALE = 2`.
  Commit `eb6b2a8`.

## Established, so nobody chases it again

Every one of these was measured on hardware, not reasoned about:

* Sectors arrive **byte perfect** at the **right offsets**. `G0651` is the 16
  bit sum of the 2048 bytes at 0x00980830 computed independently from the bin.
* **Every sector asked for is delivered.** `R` equals `F`.
* **The CPU takes all 65536 bytes** of a 32 sector read. `D0000`.
* **No interrupt is ever armed** and **the bus is never stuck**. A frame of the
  game running healthy shows the same SCSI phase as a frozen one.
* **ADPCM is idle in both failure modes** as of P13: `CTRL 00`, only
  `ADPCM_END` set, no `PLAY`, no `DMA_EN`, no `DMA_RUN`.
* `F0176` is **not** a stall. 374 sectors is simply what Rondo reads, and it
  reads the same number in runs that reach a menu.
* Timing failures are **not ours**. The violating path is inherited,
  `HUC6270:VDC0 | SPR_LINE_D` into the sprite line buffer, skew 0.413 against
  delay 0.401. `STANDARD FIT` fixes it; seeds are a lottery.

## What is open

1. **The freeze during play.** Nothing above explains it.
2. **Random sound effects.** The theory is that the ADPCM DMA takes bytes from
   a data in phase it was not meant to see: it consumes from any phase while
   `ADPCM_DMA_EN` is set and the game clears `DMA_EN` on its own schedule. That
   would put game data in ADPCM RAM, played as samples, and starve the CPU.
   **Untested, not disproven.**
3. Two of three SAPSP address forms are still unexercised.
4. Eight audio reads fail at startup with result 2, unexplained.
5. **The cheats have never been run against a CD game.** The whole point of the
   fork. `Castlevania - Rondo of Blood.cht` is on the card, five titles.

## Do this next

**Count the bytes the ADPCM DMA consumes.** `DMA_WRITE_PEND` assertions in
`cd.vhd`, on the overlay beside `DATAIN_CNT`. If that counter moves during a
plain READ6, item 2 is the answer. It is a small instrumentation build and it
settles the question without the architectural change that failed twice.

Do **not** try to hold one data in phase open across a multi sector read. It
was tried twice and 5p records why: `CD_DTR` is how the CPU learns a sector
finished, and inside a continuous phase it is low for one clock instead of
milliseconds. The per sector phase break is load bearing.

## Things that will bite

* **A single overlay frame is worth nothing.** Three times this session a
  transient was read as a fault: the SAPSP/SAPEP ordering, the title screen
  `P1`, and five seconds with no commands that was the cinematic loading
  normally. Capture a healthy frame and a broken one and diff them. That is
  what found ADPCM, and it is what proved the SCSI phase was innocent.
* **Do not narrate timing slack.** `report.sh` prints per clock worst slack and
  nothing else; there is no path in it. It is a pass or fail gate.
* **`cd.vhd` and `SCSI.vhd` are inherited and CRLF.** Write them in binary mode
  or the diff becomes the whole file.
* **`err` is sticky, `F` `W` `R` are counters.** Never read a sticky field as a
  rate.
* **Byte 0 of the file is bits [31:24] of a bridge word.**
* **Quartus exits 0 on a design that misses timing.** `report.sh` is the gate.
* **Read `build/<name>/elapsed`** rather than estimating how long anything took.
