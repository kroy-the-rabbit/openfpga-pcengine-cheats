# PC Engine / TurboGrafx-16 for Analogue Pocket, with cheats

A Pocket core for the PC Engine and TurboGrafx-16 that can apply cheat codes to
a running game.

**Based on [agg23/openfpga-pcengine](https://github.com/agg23/openfpga-pcengine)
by agg23**, whose master this forks at the point it had merged
[vanfanel's](https://github.com/vanfanel/openfpga-pcengine) fixes. It is a
Pocket port of
[TurboGrafx16_MiSTer](https://github.com/MiSTer-devel/TurboGrafx16_MiSTer) by
srg320 and greyrogue, which is in turn built on
[FPGAPCE](https://github.com/Torlus/FPGAPCE) by Gregory Estrade. Everything that
ships here is theirs apart from the cheat engine.

What this fork adds is the cheat engine and, on top of upstream's dormant CD
RTL, the host side that CD block has always needed. All of it is built by
`rtl/pce.qip` and `target/pocket/core.qip`, plus the port `cheat_poker` borrows
in `pce_top.vhd`, data slots to load codes and discs through and a few menu
switches. It also turns SuperGrafx off, which is the price of the room they
need.

| | |
|---|---|
| `cheat_poker.sv` | writes the codes into work RAM once a frame |
| `cheat_loader.sv` | parses a libretro `.cht` into code entries |
| `cheat_osd.sv` | draws the enabled cheats over the picture |
| `cheat_titles.sv` | holds their names for the overlay |
| `cheat_font.sv` | the glyphs |
| `cd_toc.sv` | parses a cue sheet into a track table |
| `cd_host.sv` | the CD drive, reimplemented from srg320's `pcecdd.cpp` |
| `cd_fetch.sv` | pulls sectors off the SD card through the APF bridge |
| `dataslot_path.sv` | opens the bin a cue names, next to the cue |
| `dataslot_probe.sv` | measures the transport, a diagnostic |

`main.sv` and `target/pocket/core_top.v` are modified to wire them in. See
[docs/CHEATS.md](docs/CHEATS.md).

> **Cheats can corrupt save files.** A PC Engine cheat is a write into the work
> RAM of a running game, made once a frame, and a game builds its save data out
> of that same memory. A code aimed at an address that means something else in
> your copy overwrites whatever is there, and the damage is written into your
> save the next time the game saves. Back up anything you care about first.

## SuperGrafx is the price of the cheat engine

`SGX_EN` is 0, which frees the second VDC, its VRAM and the VPC. That is the
room the cheat engine is built out of, and it is why the design sits near 50 %
logic and block RAM with the engine in it rather than against the ceiling.
`docs/BASELINE.md` has the measurements.

A SuperGrafx game will not run correctly on a core that no longer has the
hardware, so `.sgx` is not offered rather than offered and broken. If you want
SuperGrafx, run agg23's core: the two install side by side and this one does not
replace it.

## PC Engine CD is being built

`docs/CD-PLAN.md` is the plan. **Castlevania: Rondo of Blood boots and plays**,
verified on hardware. There is no audio yet.

The CD RTL is inherited, `rtl/pce/cd/`: `cd.vhd`, `SCSI.vhd`, `SCSI_FIFO.vhd`,
`CDDA_FIFO.vhd` and `MSM5205.vhd`. It is live now: `pce_top.vhd` passes
`EN => CD_EN` and `main.sv` drives `cd_en` from whether a cue has parsed, so a
HuCard still runs with the CD unit absent.

What made it a project rather than a switch is that MiSTer's CD block expects a
host processor running Linux to parse the cue sheet, seek the image and feed it
sectors, and the Pocket has none. The drive itself lives on that host, about
900 lines of it, and all of it had to move into the FPGA.

Working, each verified on hardware:

* **The transport.** APF target command `0x0180` reads a range of a data slot
  into the core. Measured at **1104 KB/s** with 8KB requests, 6.3 times what
  Redbook audio needs on its own. Reads are rounded to 512 byte boundaries.
* **The file layer.** `0x0190` says where the file the user picked lives and
  `0x0192` opens another next to it, so the core can be handed a cue and open
  the bin the cue names. The Pocket's file browser cannot do this by itself.
* **The cue parser.** `rtl/pce/cd_toc.sv`, streaming, no host. Track numbers,
  types, sector sizes and the byte offset of every track in the bin.
* **The drive model.** `rtl/pce/cd_host.sv`, nine SCSI opcodes, phase ordering
  and status timing as `cd.vhd` demands them. **This is a reimplementation of
  srg320's `pcecdd.cpp`**, the host-side drive model from TurboGrafx16_MiSTer,
  not original work: the opcode set, the sense codes, the track clamping and
  the decision to give seeks zero latency are all its design, moved into RTL.
  No code was copied.

There is already a working PC Engine CD core for the Pocket,
[Mazamars312's](https://github.com/Mazamars312/openfpga-pcengine-cd/), and it
solves the same problem the other way: it puts a soft CPU in the fabric and
loads it a 24KB firmware, `pce_mpu_bios.bin`, which runs the drive in software
much as `pcecdd.cpp` runs on MiSTer's Linux host. This fork does it in RTL
instead, because the point of the fork is the cheat engine and the two want the
same room. Their manifest is prior art this leaned on: the cue plus bin data
slot layout here, slot IDs included, was checked against theirs, and so was the
`version_required` floor. See `docs/CD-PLAN.md`.

Still to build: **CD-DA streaming**, which is why Rondo is silent, and ADPCM,
which is why it has no speech.

Discs must be **cue plus bin**. A bare `.iso` is the data track only, so a game
boots and plays silent, and `.chd` is compressed in a way that cannot be
seek-addressed at all: convert with `chdman extractcd` first.

This work is why `core.json` now asks for APF `version_required 2.3` rather
than `1.1`. **A Pocket on older firmware will not load this core.**

## What works

| | |
|---|---|
| Cheats, RAM pokes from libretro `.cht` files | **works** |
| **Cheats Enabled** switch, live | **works** |
| Everything upstream's core does, apart from SuperGrafx | **works** |
| Four players through the Analogue Dock | **works**, upstream's |
| Six-button controllers | **works**, upstream's |
| Controller turbo | **works**, upstream's |
| Per-game memory cards | **works**, upstream's |
| SuperGrafx | **off.** It paid for the cheat engine and it is paying for CD as well. See above |
| PC Engine CD | **in progress.** Rondo boots and plays on hardware. No CD-DA and no ADPCM yet, so it is silent. See above |
| Cartridges | not supported |
| **Show cheats**, the on-screen list of enabled cheats | **works** |
| A code store meter | not built. The store holds 32 codes, `MAX_CODES` in `cheat_poker.sv` and `cheat_loader.sv`, and the loader stops committing at it, but nothing shows how full it is |

## Versions

The five projects in this set share one version number. The set is at
**0.9999**. The next release is 0.99991, then 0.99992, and so on: each one adds
to the tail rather than climbing toward a round number. Nothing here reaches
1.0, because 1.0 is a claim to be finished and none of this is.

Provenance is stated in words, above and in the credits, rather than implied by
a number.

## Installation

Prebuilt cores are on the [Releases](../../releases) page. Download
`kroy.PCE_<version>.zip`, not the "Source code" archives: the bitstream is built
by CI rather than committed, so a core installed from a source archive is listed
by the Pocket and cannot start.

This core installs as `Cores/kroy.PCE` and shows as "PC Engine / TurboGrafx-16
(cheats)". It does not replace an upstream `agg23.PC Engine` install, it sits
beside it. APF names a core folder after the author in its `core.json`, and this
one says `kroy` because it is not agg23's build. Delete the old folder if you do
not want both listed, and its `/Settings/agg23.*` folder with it. Saves are
keyed by platform rather than by core, so they carry over untouched; save states
and settings do not.

Copy the `Assets`, `Cores` and `Platforms` folders to the root of the SD card.
Finder on macOS *replaces* folders rather than merging them the way Windows
does, which will delete the ROMs already in `Assets`, so copy the folders inside
those three rather than dragging the three themselves.

There is no boot ROM to find. This core needs none.

## Usage

ROMs go in `/Assets/pce/common/`.

Cheat files go beside the ROM, named after it: `YourGame.pce.cht`. The
[desktop app](#the-desktop-app) writes them for you, or you can write one by
hand in the libretro format.

**Cheats enabled** in the core menu turns the whole lot on and off. **Show
cheats** draws the names of the enabled cheats over the picture. Both are off at
every launch and neither is remembered, which matches the Game Boy cores.

The overlay is drawn in the core's own pixel space, ahead of the linebuffer. It
is inset from the corner rather than starting at pixel 0, because on the PC
Engine the active region is not the visible region: drawn from the corner the
leftmost cells sat in overscan and fell off the side of the panel, taking the
header's count digits and the first letter of every title with them. The inset
costs no text and nothing at pixel rate, and the panel fits inside the narrowest
mode this core produces.

[docs/CHEATS.md](docs/CHEATS.md) has the detail.

### Video, audio and controllers

Upstream's options, unchanged:

* **Use Turbo Tap** enables four players through the Dock.
* **Use 6 Button Ctrl** in Core Settings enables six-button controllers. It can
  break games that do not support them, so turn it off when you are not using
  one.
* **Turbo modes** for the `I` and `II` buttons, fired with `X` and `Y`. The
  original controllers put turbo on `I` and `II` directly; the Pocket has
  buttons to spare, so they get their own.
* **Extra Sprites** allows more sprites per line and reduces flickering in some
  games. **Raw RGB Color** uses the HUC6260's raw palette rather than the
  composite one.
* **Master Audio Boost** and **PCM Audio Boost** for games that are too quiet.

The PC Engine picks its own resolution at will and the Pocket cannot. Upstream
covers the common ones, so expect black bars on some games; the aspect ratio is
correct either way.

Each game gets its own memory card rather than sharing one, and each new save
file is pre-initialised, because some games cannot format a card themselves.

## The desktop app

[pocket-tools](https://github.com/kroy-the-rabbit/pocket-tools) is the desktop
side of this set. It reads your Pocket SD card, lists the games on it, matches
each against the libretro cheat database and writes the cheat file beside the
ROM. It will also install and update this core for you.

You do not need it. A cheat file written by hand works exactly the same. It
exists because picking cheats out of 397 database files by hand is tedious.

## Documentation

| | |
|---|---|
| [docs/CHEATS.md](docs/CHEATS.md) | what a PC Engine cheat is, how the poke reaches memory, the menu readout |
| [docs/PLAN.md](docs/PLAN.md) | design and phasing |
| [docs/BASELINE.md](docs/BASELINE.md) | measured area and timing, build by build |

## Building from source

Quartus runs in a container and nothing is installed on the host:

```sh
make pce      # -> build/pce/{bitstream.rbf_r, sd/, kroy.PCE_<version>.zip, report.txt}
make test     # the simulation suite
```

The build fails if the design misses timing. Quartus exits 0 on negative slack,
so the harness checks worst-case slack itself and stops, because a bitstream
with negative slack may work on one bench and fail on somebody's handheld.

## Where to report a problem

Cheat engine bugs belong here. Bugs in the core itself are most likely the
Pocket port's rather than MiSTer's, so they belong
[upstream](https://github.com/agg23/openfpga-pcengine/issues) and will be
forwarded from here as necessary.

## Credits

This core is other people's work with a cheat engine added.

| | |
|---|---|
| [Gregory Estrade](https://github.com/Torlus/FPGAPCE) | FPGAPCE, the original, released into the public domain |
| [srg320](https://github.com/srg320) and [greyrogue](https://github.com/greyrogue) | TurboGrafx16_MiSTer, the heavily modified MiSTer core. Its `rtl/pce/cd/` is used here unchanged, and `cd_host.sv` is a reimplementation of srg320's `pcecdd.cpp` |
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

Binary releases here are built by CI from a tagged commit of this repository,
which is the corresponding source for them.
