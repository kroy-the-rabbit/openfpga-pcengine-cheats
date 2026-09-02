# CD handoff, 2026-09-02

Read this first, then `docs/CD-PLAN.md` for the phase plan.

## Where it stands

**Rondo of Blood boots, plays, and has music.** Cue plus bin, on hardware, with
no host processor. Data path, cue parser, drive model, sector fetch and CD-DA
all verified. ADPCM works too: the Konami splash jingle plays, and it needed
nothing from the drive model.

The open problem this file was written for, the CD-DA underrun, was a byte
order bug in `cd_audio`'s drain and is fixed. See `docs/CD-PLAN.md` 5j.

P6 is done: the probe and the whole diagnostic overlay are compiled out, the
menu is clean, and slot 0 loads a System Card by itself so a cue is the only
thing a disc needs.

| | |
|---|---|
| branch | `cd-streaming` |
| last build | p6c, sisko, 10 m 31 s, setup 1.266 ns, hold 0.066 ns, 13,181 ALMs |
| worktree | `worktrees/p5` on `cd-adpcm`, started then stopped, nothing committed |
| card | P6c flashed and verified |

## What is left

**The cheats have never been tried on a CD game.** That is what the whole
project was for, and nothing has tested it: slot 2 loads a `.cht` and the
poker writes into the 8KB work RAM once a frame, which is where all five Rondo
codes point, but no run has confirmed it. Start here.

Then, none of it blocking play:

* **Two of the three SAPSP address forms are unexercised.** Rondo only ever
  uses MSF, byte 9 = 0x40. The LBA and track-number forms are written from the
  reference and have never run. Needs a game that uses them.
* **Eight audio reads fail at startup with result 2.** The count stopped moving
  after startup, so they are not in the steady state, but nothing explains them
  and what APF result 2 means is not documented anywhere in this tree. Seeing
  them again means `CD_PROBE = 1` and restoring the three DEBUG menu entries.
* **CD-DA stops at the end of a play region rather than repeating.** The
  end-behaviour byte is recorded in `cdda_mode` and what its values mean is not
  established, so the implemented behaviour is the one that fixes a hang. A
  title whose music stops when it should loop is the first sign this is wrong.
* **Opening the core cold boots the System Card** rather than prompting for a
  file, which is what `filename` on a required slot does. If a prompt is wanted
  instead, `variants.json` is an empty list and a CD variant with slot 100
  `required: true` would do it without touching logic.

## The overlay, when it is turned back on

`CD_PROBE = 0` compiles all of this out. At 1, with the three DEBUG entries
restored to `interact.json`, it reads:

    T22 C001C OD9 S0 D3 F00C9
    H 08 08 08 08 D8 D9 E0
    L00000F5D A008BE830
    A0648 E0008 K2 W8R8 U0 N0
    Q 02 40 P1 T0012 B11A4
    S01CE2580 X02EC6E30

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
