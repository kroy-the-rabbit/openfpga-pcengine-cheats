# PC Engine / TurboGrafx-16 for Analogue Pocket, with cheats

A Pocket core for the PC Engine and TurboGrafx-16 that applies cheat codes to a
running game, and runs PC Engine CD discs from the SD card.

**Based on [agg23/openfpga-pcengine](https://github.com/agg23/openfpga-pcengine)
by agg23**, whose master this forks at the point it had merged
[vanfanel's](https://github.com/vanfanel/openfpga-pcengine) fixes. It is a
Pocket port of
[TurboGrafx16_MiSTer](https://github.com/MiSTer-devel/TurboGrafx16_MiSTer) by
srg320 and greyrogue, which is in turn built on
[FPGAPCE](https://github.com/Torlus/FPGAPCE) by Gregory Estrade. Everything that
ships here is theirs apart from the cheat engine and the CD host side.

> **Cheats can corrupt save files.** A cheat writes into the work RAM of a
> running game once a frame, and a game builds its save data out of that same
> memory. Back up anything you care about first.

## What works

| | |
|---|---|
| Cheats, RAM pokes from libretro `.cht` files | **works** |
| **Cheats enabled** switch, live | **works** |
| **Show cheats**, the names of the enabled cheats over the picture | **works** |
| PC Engine CD, cue plus bin | **works** on Rondo of Blood, the only disc tested. See [docs/CD.md](docs/CD.md) |
| Everything upstream's core does, apart from SuperGrafx | **works** |
| Four players through the Analogue Dock, six-button controllers, turbo, per-game memory cards | **works**, upstream's |
| SuperGrafx | **off**, to make room for the cheat engine and CD |
| Cartridges | not supported |

The code store holds 32 codes.

## Installation

Needs Pocket firmware with APF 2.3.

1. Download `kroy.PCE_<version>.zip` from [Releases](../../releases), not the
   "Source code" archive. The bitstream is not committed.
2. Merge its `Assets`, `Cores` and `Platforms` into the SD card root. On macOS,
   copy the folders inside those three: Finder replaces folders instead of
   merging them and would delete your ROMs.

It installs as `Cores/kroy.PCE`, beside any `agg23.PC Engine` install rather
than replacing it. Saves carry over; save states and settings do not.

## Usage

- HuCard ROMs and System Cards go in `Assets/pce/common/`.
- A cheat file goes beside the ROM, named after it: `YourGame.pce.cht`. Load it
  from the **Cheats** slot.
- **Cheats enabled** turns every loaded cheat on and off. **Show cheats** draws
  their names. Both are off at every launch and never remembered.
- Discs: [docs/CD.md](docs/CD.md).

Upstream's options are unchanged: **Use Turbo Tap**, **Use 6 Button Ctrl**
(breaks games that do not support it), turbo for I and II on X and Y,
**Extra Sprites**, **Raw RGB Color**, **Master Audio Boost** and
**PCM Audio Boost**. **CD Audio Boost** is this fork's. Some games show black
bars; the aspect ratio is correct.

[pocket-tools](https://github.com/kroy-the-rabbit/pocket-tools) reads the SD
card, matches games against the libretro cheat database, writes cheat files
and installs this core. It is optional.

## Documentation

| | |
|---|---|
| [docs/CHEATS.md](docs/CHEATS.md) | what a PC Engine cheat is, how a poke reaches memory, the menu, wiring |
| [docs/CD.md](docs/CD.md) | discs: format, System Card, saves, how the drive works |
| [docs/BASELINE.md](docs/BASELINE.md) | measured area and timing |
| [tools/podman/README.md](tools/podman/README.md) | the build harness |

## Versions

Versions use `0.9999.YYYYMMDD`, where the date is UTC. Release tags add `v`,
for example `v0.9999.20260913`. Each project releases independently.
The source commit and bitstream checksums are recorded in build provenance.
A published date is not reused for a different build.

## Building

Releases are built from the tagged commit on a controlled builder with Quartus
Prime Lite 25.1std. No Quartus runs on GitHub; the release workflow only checks
the published package.

```sh
make pce      # -> build/pce/{report.txt, build.log, work/}
make dist     # -> build/pce/dist/ and a zip for the SD card root
make test     # manifest checks and the .cht parser fixtures
```

`tools/sim/run_osd.py` renders the cheat overlay and reads it back; it needs
Icarus Verilog and is not part of `make test`.

Quartus exits 0 on a design that misses timing, so `report.sh` is the gate.

## Where to report a problem

Cheat engine and CD host bugs belong here. Bugs in the core itself are most
likely the Pocket port's rather than MiSTer's, so they belong
[upstream](https://github.com/agg23/openfpga-pcengine/issues) and will be
forwarded from here as necessary.

## Credits

This core is other people's work with a cheat engine added.

| | |
|---|---|
| [Gregory Estrade](https://github.com/Torlus/FPGAPCE) | FPGAPCE, the original, released into the public domain |
| [srg320](https://github.com/srg320) and [greyrogue](https://github.com/greyrogue) | TurboGrafx16_MiSTer, the heavily modified MiSTer core. Its `rtl/pce/cd/` is used here with diagnostic counters added and its logic otherwise as it was, and `cd_host.sv` is a reimplementation of srg320's `pcecdd.cpp` |
| [agg23](https://github.com/agg23) | the Pocket port this forks, and analogue-pocket-utils |
| [vanfanel](https://github.com/vanfanel/openfpga-pcengine) | fixes to that port, merged into it before this fork and present in this history |
| [Mazamars312](https://github.com/Mazamars312/openfpga-pcengine-cd/) | the working Pocket PC Engine CD core. None of its RTL is used, but its `data.json` is the prior art the cue plus bin slot layout here was checked against |
| [spiritualized1997](https://github.com/spiritualized1997) | the TG-16 icon the core icon is based on |
| [libretro/libretro-database](https://github.com/libretro/libretro-database) | the cheat files themselves, CC-BY-SA-4.0, none of them shipped here |
| [Analogue openFPGA](https://www.analogue.co/developer) | the Pocket framework |

## License

Everything from MiSTer and from agg23 is **GPL-2.0**, unless a file says
otherwise. The cheat engine added here is under the same terms.

[FPGAPCE](https://github.com/Torlus/FPGAPCE), which this is ultimately built on,
was placed in the public domain by its author. His words, since a tweet is a
thin thing to rest a licence on:

> Indeed. The main reason why I haven't provided a license is that I didn't know
> how to deal with the different licenses attached to parts of the cores.
> Anyway, consider *my own* source code as public domain, i.e do what you want
> with it, for any use you want. (1/2)

[And](https://twitter.com/Torlus/status/1582664299973341184):

> If stated otherwise in the comments at the beginning of a given source file,
> the license attached prevails. That applies to my FPGAPCE project
> (https://github.com/Torlus/FPGAPCE).

`platform/pocket/` is not GPL. Those files are Analogue's Pocket Framework,
supplied under Analogue's own software licence agreement and the Pocket EULA
linked from their headers, which provide that where the MIT or GNU licences must
apply, those prevail.

Binary releases come from controlled builders. Each dated release includes
`BUILD.json` with the original build commit and bitstream checksums. Its
release tag may also include documentation and packaging changes; the FPGA
source is unchanged from the recorded build. The package, checksums and
timing report accompany that provenance.