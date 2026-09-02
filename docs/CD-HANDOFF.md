# CD handoff, 2026-09-02

Read this first, then `docs/CD-PLAN.md` for the phase plan.

## Where it stands

Rondo of Blood **boots and plays** from cue plus bin, on hardware, with no
host. Data path is done and verified. CD-DA is written, plumbed, and delivering
the correct bytes into the core, but **underruns continuously, so the sound is
static**. That underrun is the one open problem.

Nothing on the branch is broken. `cd-streaming` at P4c is the best build; it is
on the card as `pce.rev` sha256 `64f700b5`.

| | |
|---|---|
| branch | `cd-streaming` |
| last build | p4c, kira, 16 m 30 s, setup 1.150 ns, hold 0.100 ns, 14,335 regs, 246 M10K |
| worktree | `worktrees/p5` on `cd-adpcm`, started then stopped, nothing committed |
| card | P4c flashed and verified, left mounted |

## What the last screenshot proves

    T22 C001C OD9 S0 D3 F00C9
    H 08 08 08 08 D8 D9 E0
    L00000F5D A008BE830
    BE5E5E5E5 WBRB GE8E1CAF0
    Q 02 40 04 57 41 00 P1 N0
    S01CE2580 X02EC6E30 K2

Settled, and not worth re-testing:

* **Addressing is right.** `X02EC6E30` is exactly the cue's byte offset for LBA
  22166, computed by hand. `S01CE2580` lands on an exact sector boundary in
  track 3.
* **The bytes in the ring are right.** `G` is the first frame drained after a
  restart. `E8E1CAF0` is byte for byte what the bin holds at `S`: samples
  -7704 and -3894, little endian. Offsets, transport, ring addressing and byte
  order are all correct together.
* **The fetcher runs.** `W` and `R` both at 0xB. The P4b deadlock, where a
  restart abandoned an in-flight transport command and lost its completion, is
  fixed by deferring the restart to A_IDLE.
* **SAPSP and SAPEP decode correctly**, at least in MSF form. Byte 9 is 0x40,
  the top two bits select MSF, and the resulting offset checks out. The other
  two address forms are still unexercised.

## The open problem

`W == R` with `N0`. The ring is 8 chunks of 2048 bytes and it never holds more
than one. The drain is consuming exactly as fast as the fetcher supplies,
instead of the fetcher running 8 chunks ahead, so every gap in supply is an
underrun and the CDDA FIFO gets sparse frames. That is the static.

`K2` says at least one audio read returned APF result 2. `err` is sticky, so
that could be one failure or every one after the first. **Make it a counter
before theorising.**

Ranked hypotheses, none verified:

1. **Audio reads are erroring, so most fetches deliver nothing** and the ring
   only advances on the ones that work. `K2` is the thread to pull. What APF
   result 2 means is not documented anywhere in this tree. Two clients issuing
   `0x0180` against the same slot 101 with different offsets is the obvious
   suspect: `cd_fetch` and `cd_audio` share it.
2. **The fetcher is not getting the port often enough.** Audio has top priority
   in `core_top`'s arbiter, but ownership is only re-evaluated while
   `!tcmd_ack`, so a long data burst can hold it off. 201 sectors were fetched
   in the same window.
3. **`have_room` is reading wrong.** It is `wr_chunk - rd_in_74 < 8` across a
   Gray-coded crossing. If `rd_in_74` lags or decodes wrong, the fetcher would
   only ever fetch one chunk behind the drain, which is exactly the observed
   lockstep. `from_gray` assigns to bit-selects of the function return; that is
   legal SystemVerilog and worth confirming Quartus built what it says.

## Next session, in order

1. Turn `err` into a counter plus last code, and add a fetch counter for
   `cd_audio`, so the ratio of attempts to failures is visible. One build.
2. From that, pick between the three hypotheses above.
3. If reads are erroring because the slot is shared, the fix is probably a
   second deferload slot holding the same bin, opened separately for audio.
   `data.json` has room and `dataslot_path` already knows how to open one.

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

## Not started

P5 is ADPCM plus the SCSI edge cases, and it is smaller than the plan assumed:
`ADPCM_DRAM` is a `dpram(17,4)` **inside `cd.vhd`**, and its DMA pulls straight
off the SCSI bus during a data-in phase. It needs nothing from the drive model.
The mixer is already wired and ungated: `CDDA_EN`, `ADPCM_EN` and `PSG_EN` are
hardwired to 1 in `target/pocket/audio.sv`, and `cd_audio_boost` defaulting to
0 does not mute, it just adds one copy instead of two.

Two real gaps found in `cd_host.sv` while scoping P5, both still open:

* `aud_ended` is an input that nothing consumes. When CD-DA reaches the end
  position, `dstate` stays `DS_PLAY` forever. A game polling READSUBQ for track
  end waits for ever.
* `READSUBQ` reports `lba`, the data read head, not the audio play position.
  `cd_audio` would need a sector counter for this; a CD-DA sector is 2352 bytes
  which is exactly 588 stereo frames, so it costs a counter and no divide.
