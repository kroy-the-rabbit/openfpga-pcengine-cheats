# CD handoff, 2026-09-02

Read this first, then `docs/CD-PLAN.md` for the phase plan.

## Where it stands

**Rondo boots and the opening cinematic plays with its music.** Cue plus bin,
on hardware, with no host processor. Data path, cue parser, drive model,
sector fetch, CD-DA and ADPCM all run.

It does not get further. At the menu one sound plays, cuts off and stops.
Starting the game creates a save and then hangs on a black screen.

`docs/CD-PLAN.md` 5k has the analysis. In short: a data read was knocking the
drive out of `DS_PLAY`, so `READSUBQ` reported the wrong status and the wrong
position for the whole of every track that had a read in it, and the end of a
region was never consumed. That is fixed. Why the menu sound cuts off is not
settled and the overlay is back on to settle it.

| | |
|---|---|
| branch | `cd-streaming` |
| last flashed | p6c, sisko, 10 m 31 s, setup 1.266 ns, hold 0.066 ns, 13,181 ALMs |
| worktree | `worktrees/p5` on `cd-adpcm`, started then stopped, nothing committed |

## What to do with the next run

`CD_DIAG` is 1, so the six rows draw over a loaded cue with **Show cheats**
on. `CD_PROBE` stays 0: the rows come from `cd_host` over `cd_enable` and need
neither probe module nor a menu entry. The two used to be one switch.

Note the margin: P7b meets hold by 8 ps, and P7a missed by 17 ps with 41
fewer ALMs. Hold in that domain is placement noise at 80% occupancy, so treat
a debug build's timing as luck rather than headroom, and check `report.sh`
every time. Setup is not close in either: 1.760 and 1.865 ns. Two readings decide everything:

* **`Z` on row 4, at the moment the menu sound cuts off.** If it steps, the
  region reached the end offset row 5 shows, and the question is whether that
  offset is right or whether the track was meant to repeat. If it does not
  step, a command stopped the audio, and `Q` and `R` on the same row say which
  one and with what mode byte. `Q` is SAPSP's byte 1, `R` is SAPEP's.
* **`Y` on row 2 against `F` on row 0, at the black screen.** `Y` running
  while `F` stands still is a game polling the drive for an answer it never
  gets. Both frozen means the core stopped asking. `F` still climbing means
  data is flowing and the hang is somewhere else.

`SAPEP` still writes `aud_play` and `dstate` from its mode byte, which its own
comment says it should not. Left alone deliberately, so that this run measures
the current behaviour rather than a changed one.

## What is left after that

**The cheats have never been tried on a CD game.** That is what the whole
project was for. `Castlevania - Rondo of Blood.cht` is on the card in
`Assets/pce/common/`, five titles and six pokes, all pointing into the 8KB
work RAM the poker already writes. Nothing has confirmed it runs.

Then, none of it blocking play:

* **Two of the three SAPSP address forms are unexercised.** Rondo only ever
  uses MSF, byte 9 = 0x40. The LBA and track-number forms are written from the
  reference and have never run. Needs a game that uses them.
* **Eight audio reads fail at startup with result 2.** The count stopped moving
  after startup, so they are not in the steady state, but nothing explains them
  and what APF result 2 means is not documented anywhere in this tree.
* **A multi-sector READ6 that crosses a track boundary** keeps the track it
  started in. Rondo's data is one track so it has never mattered.

## The overlay, when it is turned back on

`CD_DIAG = 0` compiles the rows out; `CD_PROBE` is separate and gates only the
two probe modules. With `CD_DIAG = 1` and **Show cheats** on it reads:

    T22 C001C OD9 S0 D3 F00C9
    H 08 08 08 08 D8 D9 E0
    L00000F5D A008BE830 Y0142
    A0648 E0008 K2 W8R8 U0 N0
    Q 02 40 R 00 40 P1 Z0003
    S01CE2580 X02EC6E30

Row 2 gained `Y`, READSUBQ commands answered. Row 4 lost the two throughput
fields, which had done their job, and gained SAPEP's mode bytes as `R` and the
end-of-region count as `Z`. `cd_host.sv` carries the full legend.

Reads over playback seconds is the chunk rate and should be 86: 1608 over 18
is 89. Busy milliseconds over reads is what one read costs: 4516 over 1608 is
2.81 ms, which is what the probe measures standalone. `E` has not moved from 8
since startup, so failures are not in the steady state.

## Things that will bite

* **`err` is sticky, `F`/`W` are counters.** Do not read a sticky field as a
  rate. This already cost one round trip.
* **`last_lba` and `last_off` now latch together per sector.** Before P4c they
  did not, and a 32 sector READ6 reported two different points and looked like
  an offset bug. It was not.
* **`E5E5E5E5` in the sector head is real disc content**, not a failed read.
  Verified against the bin.
* **Quartus exits 0 on a design that misses timing.** `tools/podman/report.sh`
  is the gate. The flash script in this session checked `timing met` before
  writing to the card and should stay that way.
* **Do not read elapsed time from a sense of how long a build took.** Read
  `build/<name>/elapsed`.
* **Byte 0 of the file is bits [31:24] of a bridge word, not [7:0].** The
  bridge writes big-endian because `core_top` ties `bridge_endian_little` low.
  `cd_fetch` gets this right; `cd_audio` had it backwards for four builds and
  the header asserted it was right, which is what kept it invisible. File order
  is not low bits first.
* **A rate needs both of its units checked.** One build was spent on a counter
  of seconds since reset read as though it were seconds of playback.
