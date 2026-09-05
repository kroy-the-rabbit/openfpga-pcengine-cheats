# CD handoff, 2026-09-04

Read this, then `docs/CD-PLAN.md`, 5k to 5s for the last sessions.

## Where it stands

**Rondo boots and reaches live stage play** from cue plus bin on hardware with
no host processor. p19 fixed the phase-dependent shared data-bus corruption
found after p18, and its hardware counters prove that the fixed collision case
was exercised. Repeatability across cold launches is not established yet.

**Rondo is the release target and current hardware evidence.** The user may
test additional cue files later as optional follow-up coverage.

**p24 is the current release candidate.** It removes the CD diagnostics that
p23 mistakenly left under `Show cheats`. Hardware presentation remains.

| | |
|---|---|
| branch | `cd-streaming`, p24 release fix `d5d93c8`; p21 functional source `b86a38b` |
| working tree | this handoff update is uncommitted; p24 artifacts and hardware evidence are ignored under `build/` |
| on the card | p24 installed and hash-verified. Hardware pass reported by Kroy 2026-09-04: `Show cheats` clean, menu order confirmed, HuCard save regression and CD cheat test passed, Rondo repeated |
| build | p24 on Kira, 1218 seconds, 13,026 ALMs, all timing passed |
| card save | cue-named Rondo save reloads at 4 percent; root `.sav` remains absent |
| card state | mounted `rw` at `/run/media/kroy/pocket`; leave mounted |
| worktree | `worktrees/p5` on `cd-adpcm`, nothing committed |

p19 and p20 screenshots plus the candidate CD saves are copied off the
removable card under ignored `build/evidence/`. p21 was built, timing-clean,
packaged, installed, hash-verified, and proven to create and reload a
cue-derived save. Its pre-write and post-stage-0 save states are byte-verified
locally under `build/evidence/p21/`. p23 was installed and hash-verified, then
rejected because its `Show cheats` overlay still contained the doubled CD
diagnostic block. p24 removes that block and is now installed and
hash-verified.

## What p19 found

The three diagnostic screenshots all show `U0158 W0000`. `U` counts registered
audio tail requests that held off a SCSI byte which the old arbitration would
have pushed. `W` counts actual `data_wr && audio_wr` overlap. The avoided case
occurred 344 times, no overlap remained, and the next screenshots show normal
boss and stage gameplay. The p19 arbitration fix is positively exercised.

The first p19 launch still behaved strangely: it saw no old record, a newly
created record claimed 32 percent completion, and game startup was corrupted.
After reboot, deleting that record and creating another led to normal play.
The card explains the missing record separately. The old CD save is
`Saves/pce/common/bios_3_0_jap.sav`; the latest is `Saves/.sav`. APF was naming
the nonvolatile slot before it encountered the selected cue.

p20 reorders the first manifest slots to `0, 100, 1`: Cartridge or System Card,
cue, Save. This preserves HuCard naming and makes the cue name a CD save. The
save-size datatable write moved from manifest index 1 to index 2, and the
manifest checker enforces both facts. The good root `.sav` was not migrated,
but APF reused it anyway. p20 showed the existing `BRO` record at 4 percent,
reached normal stage play, and updated that same root save by one byte on exit.
Persistence therefore passes across the p19 to p20 core replacement. A later
fresh launch also created root `Saves/.sav`, not a cue-named save. The reorder
does not fix CD save naming in this combined core.

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
now makes audio ownership include `aud_req`, not only `aud_busy`, and its
hardware counters show 344 avoided opportunities with no remaining overlap.

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

1. HuCard save naming after restoring the manifest to `0, 1, 2, 100, 101`.
2. Repeat CD stage play enough to assess the former random or looping sound
   effects after the data-bus fix.
3. Two of three SAPSP address forms remain unexercised.
4. Eight audio reads fail at startup with APF result 2, unexplained.
5. ~~Cheats have never been run against a CD game.~~ Closed 2026-09-04: Kroy
   reports cheats verified on cue plus bin against p24, from
   `Castlevania - Rondo of Blood.cht`, five titles, six pokes.
6. Whether `STANDARD FIT` should be the project default rather than an env var.

## p20 hardware result and next work

The first p20 run loaded the old root `.sav`, showed `BRO` at 4 percent, and
reached normal stage play. The final overlay is `F0176 R0176 U0144 W0000`.
The save changed at one byte after exit, proving that the same file was loaded
and flushed. This is one complete p20 pass and a second successful run of the
p19 arbitration fix.

The approved fresh test is complete. The old record was absent and Rondo
required both opening cartoons. The user completed stage 0 and began stage 1
without a fault. A gameplay screenshot and its diagnostic counterpart were
copied under ignored `build/evidence/p20/fresh-save/`; the overlay shows
`U02BF W0000`.

APF created a new 2048-byte root `Saves/.sav` at 09:25:24. It created no
cue-named file under `Saves/pce/common/`. The fresh save has SHA256
`e0a82c5310f69e5d73d73452e143d45fa3c6090f66604b55d210368399eabcff`,
begins with `HUBM`, contains `DRACULA X`, and differs from the old image at 46
byte positions. The old image remains preserved as
`Saves/.sav.p20-pre-fresh-test`, SHA256
`b0114f4883532e6c83f2d0e83bc532d9cda3e9f6583c639809ca46c39f7dcd7e`.
Both were copied and byte-verified locally before analysis.

Reset was pressed while trying to quit. The new save exists and is
structurally recognizable, so the reset did not prevent a write, but a relaunch
is still needed to prove the new record loads. That relaunch can also supply
the third gameplay pass.

After byte verification and cataloging, the user chose to remove the wrong
fresh root `.sav`. The two follow-up screenshots were also removed under the
standing capture policy. Their local copies remain under
`build/evidence/p20/fresh-save/`. The preserved old image remains on the card
as `.sav.p20-pre-fresh-test`. The card is mounted for continued development.

The fresh naming test therefore fails: manifest order `0, 100, 1` still gives
APF a root save name. Do not describe p20 as a CD save-naming fix. The next
implementation must be built, installed and hardware-tested as a new artifact.

The authoritative APF rule is that bit 2 clones a nonvolatile name from the
primary data slot, defined as the first entry in `data.json`. It does not use
the nearest preceding selected slot. A combined core cannot make both slot 0
HuCards and later slot 100 cues primary through ordering. The next experiment
therefore keeps the proven combined launch flow and uses target command
`0x0192` to bind save slot 1 explicitly to a path derived from the selected
cue, followed by `0x0180` to load that file before releasing CD reset.

## p21 hardware result and next work

p21 implements that explicit binding in functional commit `b86a38b`. The
manifest is back to `0, 1, 2, 100, 101`, preserving the HuCard automatic save
relationship. After a cue parses, `dataslot_path.sv` changes the selected
`/Assets/.../name.cue` path to `/Saves/.../name.sav`, opens it into slot 1, and
loads 2048 bytes through `0x0180`. A newly created zero-length file is reopened
with resize, but an existing save is never opened with truncate. CD reset now
remains asserted until both the bin and runtime-bound save are ready.

The exact commit was built on sisko in a fresh detached checkout. The fit took
831 seconds, used 15,021 of 18,480 ALMs, and passed every timing analysis.
Worst setup slack is `+2.408 ns`; worst hold slack is `+0.072 ns`. The raw RBF
SHA256 is
`ccd397d2b80022ce9cba62859b7c43162f4a81e519ddf9fde3f9d7a1dff14992`.
Local packaging produced `pce.rev` MD5
`37589416822862010413a4af78ab318a`; packaged `data.json` SHA256 is
`238bd3495b79c60345262382558a4541503080d6495ecdc546925194d81d9f19`.
The candidate is under ignored `build/p21/` and those hashes were verified on
the card after installation.

The save test passes. The fresh launch created the 2048-byte file
`Saves/pce/common/Castlevania - Rondo of Blood.sav`; root `Saves/.sav` remained
absent. A live copy during the opening sequence had SHA256
`2de0d66eee36dade46201567821d98ae5fa5885893e2d16fd0bda899307b422f`.
The user completed stage 0, exited, and relaunched. Rondo loaded the record at
4 percent, its completed-stage-0 state. The file had changed to SHA256
`8128add46b7934a761df2f76fd200540d72e31805d96ffed12e40c919318bb3a`.
Both states were copied from the card and byte-verified locally. This proves
cue-derived naming, writeback through the rebound slot, and load on relaunch.

The remaining save test is a HuCard with an established record. It must still
use its game-derived automatic name and load correctly with the restored
manifest order.

Copy every screenshot and save result to ignored local evidence and verify its
hash before removing any exact captured file from the card.

## Release alignment

The current built candidate is p24 from exact commit
`d5d93c85f80f8be3418a34e7348b330ecd1ba24a`. Kira built it with Quartus Lite
25.1std build 1129 in 1218 seconds. It uses 13,026 of 18,480 ALMs and passed
all timing analyses: setup `+2.193 ns`, hold `+0.098 ns`, recovery
`+14.547 ns`, removal `+0.178 ns`, and minimum pulse width `+0.831 ns`.
Kira uses low-voltage CPUs, so its longer duration relative to Sisko is
expected and is not a fit regression.

The p24 raw RBF SHA256 is
`271a41ff73669c9107cdb789612e76fc1fabcaca635c1172c7bfdd8d5bc8a92d`.
The packaged `pce.rev` has SHA256
`02b60ec58b1bc4f0fae8ee5970c81a220d04a269a0f0e86024682ee633c8fd4e`
and MD5 `9166007471fd51913201f632d3ace3d6`. Packaged `data.json` has SHA256
`37efbe60ab3bdc8cc06bb0021fac6ddb6dadb47facb98dfd03a596fbb448d009`.
Packaged `info.txt` has SHA256
`9714ec38eabbd50c69981d2c78cc8d5fa4d42378b3a7852cf6559e34dba3c3e3`.
The development package `kroy.PCE_0.9999.zip` has SHA256
`6398d58d2a808d22f8b5b9873caf745310ea5121b35f64903fb1085579e3cac9`.
Local `make test` and `make dist BUILD_NAME=p24` passed. The packaged manifest
has the visible loader order `Cartridge`, `Disc (cue)`, then `Cheats`.

Commit `d5d93c8` sets `CD_DIAG = 0` and `CD_DIAG_SCALE = 1`, so `Show cheats`
contains only its normal header and cheat list. `make test` now enforces both
release values. Removing the diagnostic block reduced utilization by 1,995
ALMs relative to p23.

The first ordinary-user p24 `rsync -av` reported copying the package, but the
post-copy hash still identified the p23 bitstream. A checksum-based
`rsync -avc` then copied `pce.rev`, and all three installed SHA256 checks
matched the p24 package values above. Always verify content hashes after a card
copy. The card remains mounted and must not be unmounted unless explicitly
requested.

p21 remains the last hardware-tested installation. It passed CD save creation,
writeback, and reload at 4 percent. p24 retains that functional logic and is
the candidate for the next hardware pass.

Before tagging or packaging a release, all reported done by Kroy 2026-09-04
against the installed p24:

1. `Show cheats` contains only the normal cheat header and list. Done.
2. Visible menu order confirmed on hardware; HuCard save regression and CD cheat
   test passed. Done. The detail belongs in `docs/CD-PLAN.md` and is not yet
   written there.
3. Rondo gameplay repeated. Done.
4. Push and tag were explicitly requested 2026-09-04. The release is
   `v0.9999.d5d93c8` on exact commit `d5d93c8`, from the p24 bitstream
   repackaged with `RELEASE_NAME=v0.9999.d5d93c8 BUILD_NAME=p24 make dist`:
   same `pce.rev`, `data.json` and `info.txt` hashes as above, `core.json`
   stamped `0.9999.d5d93c8`.

## Things that will bite

* **Screenshots come off the card**, `/run/media/kroy/pocket/Memories/
  Screenshots/`. Nowhere else. Check the mount before concluding anything.
  Copy, hash-verify and catalog each batch locally, then remove that verified
  batch from the card.
* **Find the card by mount point, not `/dev/sdX`.** The letter moves between
  insertions. Use `findmnt -rn -T /run/media/kroy/pocket -o
  TARGET,FSTYPE,OPTIONS`; do not capture or reuse the source device name.
* **Merge onto the card, never `--delete`.** Saves, cheats, discs and dumps
  live there. Unmount only when told.
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

Builds run on a remote runner, never locally and never in CI. The private
orchestrator now provides the restricted shared command
`/home/kroy/Desktop/repos/pocket-dev/tools/runner-build`. It admits only known
runner and repository profiles, refuses a runner with an existing Quartus
process, and holds a per-runner lock for managed jobs. Use it for new starts,
status, job inspection, and artifact fetches. p20 used kira
LXC 151 directly at `root@10.50.1.245`; all six public SSH keys published by
the `kroy-the-rabbit` GitHub account are installed there. `jq` and `ripgrep`
were also installed, so the runner now completes the manifest checks and
packaging instead of ending with the old `jq` return code 127.

The p20 source was a tracked-file archive of the live worktree, including the
uncommitted p19 and p20 changes, extracted at
`/root/pocket-pcengine-p20-20260903`. The exact source hashes recorded in the
build are:

* `rtl/pce/cd_host.sv`: `07b545312fe9b94bb66d79d94971e82818756cb031f5a3c51fcff0f1d55bfc5b`
* `target/pocket/core_top.v`: `f894bb2190d186b0ec5b46bbb15ce350de0deb395bbabfa117bede8bccf8ce5e`
* `pkg/Cores/kroy.PCE/data.json`: `af25fd012cf074dc28614e190c4beb27685ebf51bbb8773de6c4346669f7c732`

The build command was `FITTER_EFFORT="STANDARD FIT" NPROC=16 BUILD_NAME=p20
tools/podman/build.sh`. The runner output is under that checkout's
`build/p20/`; the pulled and locally packaged output is `build/p20/dist/`.
Merge that directory onto the mounted card without `--delete`, run `sync`, and
verify both `pce.rev` and `data.json` in place. The sandbox can misreport the
card as read-only, so request elevation outside the sandbox for the copy. Do
not remount the card and do not unmount it unless told.

p21 was built from a Git bundle in the detached sisko checkout
`/root/pocket-pcengine-p21-20260903`. Its results were fetched through the
shared interface into `build/p21/`, then packaged locally with
`make dist BUILD_NAME=p21`. The package was merged onto the card and both
`pce.rev` and `data.json` matched the p21 hashes in the dedicated section
above. Do not use the p20 values in the historical paragraph.

p23 was built from exact commit `c02592f` through `tools/runner-build` on Kira
and fetched into ignored `build/p23/`. Kira's low-voltage CPUs make it slower
than Sisko. The fit passed all timing, and `make dist BUILD_NAME=p23` produced
the hashes in the release-alignment section. The package was merge-copied to
the card and its three changed files were hash-verified. It is rejected because
the release-facing `Show cheats` overlay still contained CD diagnostics.

p24 was built on Kira through `tools/runner-build` from exact commit
`d5d93c85f80f8be3418a34e7348b330ecd1ba24a`, fetched into ignored
`build/p24/`, packaged locally, and installed with a checksum-forced merge
copy. Its timing and installed hashes match the release-alignment section.
