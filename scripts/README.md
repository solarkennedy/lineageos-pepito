# Scripts — bench build/flash tooling

Working tooling from the bring-up, preserved for the record. Bench-specific
absolute paths (`/home/kyle/…`, `flash-staging/`, the remote build box)
throughout — read before running. In the bench tree these live behind a
`scripts/` symlink at the source-tree root.

## Build / flash flow

| Script | What it does |
|---|---|
| `build-lineage23.sh` | full build entry point (envsetup, lunch `lineage_Mi8937-bp4a-userdebug`, image set) |
| `build-lineage23-remotely.sh` | same, on the remote build server via rsync |
| `prepare-flash.sh` | stages a flashable set: sparse→raw system/vendor, **signs boot/recovery for the PVG100 bootloader**, zeroes the FBE header (forces fresh `/data` format) |
| `backup-to-archive.sh` | bench backup |
| `clear-ramoops.sh` | clears pstore/ramoops between crash captures |
| `shutdown-phones` | powers down the bench devices |
| `mpss-reasm.py`, `mpss-strings-vaddr.py` | modem-firmware analysis helpers (the modem saga) |

## boot-signing/ — making a PVG100-bootable boot image

The Palm PVG100 bootloader implements **AVBv1** (`BOOT.BF.3.3 boot_verifier`):
it verifies a DER `BootSignature` appended to `boot.img`. Without a valid
signature the device will not boot the image — aboot warns, then powers off
after 30s (RED state). This device predates AVB 2.0 entirely: there is no
`vbmeta` and `BOARD_AVB_ENABLE := false`.

- `scripts/sign-boot.py` — **the** script. Creates the private signing key on
  first run (idempotent; `--regen` replaces it), appends the AVBv1
  `BootSignature`, fixes up `img_size`/id, and self-verifies the result. This is
  what makes a boot image pepito-compatible. Called by `prepare-flash.sh`.
- `scripts/verify-boot-sig.py` — re-checks any signed image. Reads the cert out
  of the image itself, so it needs no key and works on foreign/stock images too.

Originally from the predecessor project
(`~/Projects/android-pepito-pvg100-kernel-upgrade`). The mkbootimg wrapper and
flash-staging copy that came with it were stale relics targeting the old tree and
are gone — `scripts/flash-staging.sh` is the live one, and `extract-dtbs.py`
moved up to `scripts/` since it is DTB tooling, not signing.

**Keys:** the private keypair lives at `vendor/lineage-priv/keys-boot/` in the
build tree — **never in this repo** — and is auto-created on first run. Losing it
is not a brick; it only changes the fingerprint on the yellow screen.

### Trust model — corrected 2026-07-16 (the previous version of this section was wrong)

aboot tries its built-in OEM keystore first (Palm's key → GREEN, unobtainable
outside TCL). On mismatch it falls back to the pubkey of the cert **embedded in
the image's own signature block** → YELLOW. The `keystore` partition
(`mmcblk0p33`) is all zeros, so yellow is always that self-embedded path: at the
*bootloader* level the key is pinned to no root of trust, and any RSA-2048 key
boots yellow.

This section used to conclude "there is no meaningful secure boot on this device
— anyone can sign a bootable image with a public key." **That was a consequence
of signing with the public AOSP test key, not a property of the device.** aboot
feeds the boot key digest to the keymaster TA as Root of Trust, and that ROT is
mixed into keymaster's key derivation — flash-validated 2026-07-16 by booting a
differently-signed image and getting the "decryption unsuccessful" prompt. So:

- An attacker who reflashes a boot image signed with *their* key **cannot decrypt
  existing user data**. TEE-enforced, no user vigilance required. That boundary
  exists only because the signing key is private.
- The flip side: **changing the key on an existing install forces a wipe.** It is
  a pre-ship decision, not a later tweak.
