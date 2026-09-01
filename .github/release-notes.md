**Download `kroy.PCE_<version>.zip` below**, not the "Source code"
archives. Those are the repository, and the bitstream is built by CI rather
than committed, so a core installed from one is listed by the Pocket but cannot
start: *error in framework, can't find bitstream*.

## Installing

Unzip and merge `Assets`, `Cores` and `Platforms` into the root of the SD card.
This installs as `Cores/kroy.PCE`, beside any `agg23.PC Engine` install
rather than replacing it, and shares `Assets/pce` with it so ROMs and saves are
not duplicated.

On macOS, Finder **replaces** a folder instead of merging it, which deletes the
ROMs already in `Assets`. Copy the folders inside `Assets`, `Cores` and
`Platforms` rather than dragging the three top-level ones.

No BIOS is needed. Put `.pce` ROMs in `/Assets/pce/common`.

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

## Differences from the upstream agg23 port

* Cheats.
* SuperGrafx is removed to make room, for the cheat engine and for the CD work
  behind it. `.sgx` files still load but render as plain PC Engine and will not
  look right.
* **Swap ROM Bit Order** for US TurboChip dumps taken bit-reversed.
* CD-ROM is not supported yet. It is being built: see `docs/CD-PLAN.md`.

## Checking a download

```sh
sha256sum -c SHA256SUMS --ignore-missing
```

Cheats are documented in [docs/CHEATS.md](https://github.com/kroy-the-rabbit/openfpga-pcengine-cheats/blob/main/docs/CHEATS.md).
