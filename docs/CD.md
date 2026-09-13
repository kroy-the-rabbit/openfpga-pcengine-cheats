# PC Engine CD

Discs run from the SD card as **cue plus bin**, with no soft CPU and no
firmware: the drive MiSTer runs on its Linux host is reimplemented in RTL.

## Tested

Castlevania: Rondo of Blood, from a single-bin cue: boots, plays both opening
cinematics with music, completes stage 0, starts stage 1, reloads its save,
and takes cheats. It is the only disc tested. Multi-bin sets are not a
compatibility claim.

## Using it

1. Put a System Card in `Assets/pce/common/`. The Cartridge slot defaults to
   `bios_3_0_usa.pce`, then `bios_3_0_jap.pce`, `bios_2_0_usa.pce`,
   `bios_2_0_jap.pce` and `bios_1_0_jap.pce`. Rondo needs a 3.0 card.
2. Pick the `.cue` in **Disc (cue)**. The core opens the bin the cue names,
   beside the cue.
3. The save is `Saves/pce/common/<cue name>.sav`, created on first launch.

A bare `.iso` is the data track only and plays silent. A `.chd` cannot be
seek-addressed; convert it first:

    chdman extractcd -i "Game.chd" -o "Game.cue" -ob "Game.bin"

Needs Pocket firmware with APF 2.3 (`version_required` in `core.json`).

## How it works

| Module | Job |
|---|---|
| `rtl/pce/cd/` | inherited CD block: `cd.vhd`, `SCSI.vhd`, `SCSI_FIFO.vhd`, `CDDA_FIFO.vhd`, `MSM5205.vhd` |
| `cd_toc.sv` | parses the cue into a track table |
| `cd_host.sv` | the drive: nine SCSI opcodes, phases and status timing, reimplemented from srg320's `pcecdd.cpp` |
| `cd_fetch.sv` | reads sectors through APF `0x0180` |
| `cd_audio.sv` | CD-DA from a 16 KB ring of the bin at 44.1 kHz |
| `dataslot_path.sv` | `0x0190` and `0x0192`: opens the bin beside the cue and binds the save slot to the cue name |
| `cd_diag.sv` | diagnostic overlay, `CD_DIAG = 0` in releases, enforced by `make test` |

The transport measures 1104 KB/s with 8 KB requests. ADPCM needs no host
side: its RAM and DMA live in `cd.vhd`.

[Mazamars312's core](https://github.com/Mazamars312/openfpga-pcengine-cd/)
solves the same problem with a soft CPU and firmware. None of its RTL is used;
the cue plus bin slot layout here was checked against its `data.json`.

## Open

- Two of three SAPSP address forms are unexercised.
- Eight audio reads fail at startup with APF result 2.

## Development notes

- `cd.vhd` and `SCSI.vhd` are CRLF. Write them in binary mode.
- Each sector needs its own data-in phase: `CD_DTR` is how the CPU learns a
  sector finished.
- PREGAP goes in the LBA, not the byte offset.
- Build with `STANDARD FIT`, the Makefile default; AUTO FIT misses hold on
  this design. See `docs/BASELINE.md`.
