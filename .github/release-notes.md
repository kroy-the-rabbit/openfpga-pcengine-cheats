**Download `kroy.PCE_<version>.zip` below**, not the "Source code"
archives. Those are the repository, and the bitstream is not committed, so a
core installed from one is listed by the Pocket but cannot start: *error in
framework, can't find bitstream*.

## Installing

Unzip and merge `Assets`, `Cores` and `Platforms` into the root of the SD card.
This installs as `Cores/kroy.PCE`, beside any `agg23.PC Engine` install
rather than replacing it, and shares `Assets/pce` with it so ROMs and saves are
not duplicated.

On macOS, Finder **replaces** a folder instead of merging it, which deletes the
ROMs already in `Assets`. Copy the folders inside `Assets`, `Cores` and
`Platforms` rather than dragging the three top-level ones.

HuCard games need no BIOS. Put `.pce` ROMs in `/Assets/pce/common`.

PC Engine CD games require a System Card image in `/Assets/pce/common`. The
core looks for `bios_3_0_usa.pce` first, with Japanese 3.0 and older System
Cards as fallbacks. Put a single-bin `.cue` and its `.bin` together under
`/Assets/pce/common`, then choose **Load Disc (cue)**. Bare ISO and CHD files
are not supported.

**This core needs Pocket firmware supporting openFPGA 2.3.** It declares
`version_required 2.3`, and an older firmware will refuse to load it.

## Cheats

Put a libretro `.cht` file beside the ROM and pick it in the **Cheats** slot,
then turn on **Cheats enabled**. **Show cheats** draws the list over the
picture, since the Pocket menu cannot name a cheat.

Every PC Engine cheat is a RAM poke, and whether one is on comes from the file
itself via its `cheatN_enable` key, not from the menu. Files straight out of
libretro's database ship with everything disabled, so a file has to be edited
or generated with the cheats you want turned on.

The file loaders are ordered as **Load Cartridge**, **Load Disc (cue)**, then
**Load Cheats**.

## PC Engine CD

This release adds a host-free CD drive in FPGA logic. It parses cue sheets,
streams data and CD audio from the bin, and stores backup RAM under the cue's
name: `Saves/pce/common/<cue name>.sav`. Castlevania: Rondo of Blood was
verified through both opening cinematics, stage 0, the start of stage 1, a save
reload at 4 percent completion, and cheats applied from a `.cht` beside its cue.

**One disc has been tested.** Every CD claim above is a claim about Rondo. The
verified format is one cue plus one bin; multi-bin compatibility is not claimed.

**Show cheats** contains only the cheat header and list. The CD diagnostics that
earlier development builds drew there are gone.

## Differences from the upstream agg23 port

* Cheats.
* SuperGrafx is removed to make room, for the cheat engine and for the CD work
  behind it. `.sgx` files still load but render as plain PC Engine and will not
  look right.
* **Swap ROM Bit Order** for US TurboChip dumps taken bit-reversed.
* PC Engine CD support from cue plus bin, including CD audio and cue-named
  backup RAM saves.

## Checking a download

```sh
sha256sum -c SHA256SUMS --ignore-missing
```

Cheats are documented in [docs/CHEATS.md](https://github.com/kroy-the-rabbit/openfpga-pcengine-cheats/blob/main/docs/CHEATS.md).
