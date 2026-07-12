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
it verifies a DER `BootSignature` appended to `boot.img` against a certificate
it trusts. Without a valid signature the device will not boot the image.

Copied from the predecessor project
(`~/Projects/android-pepito-pvg100-kernel-upgrade`, its canonical home):

- `scripts/sign-boot.py` — appends the AVBv1 `BootSignature` (also fixes up
  `img_size`/id); **this is the thing that makes a boot image
  pepito-compatible.** `verify-boot-sig.py` checks one.
- `scripts/build-bootimage.sh`, `scripts/flash-staging.sh`,
  `scripts/extract-dtbs.py` — mkbootimg wrapper, flash staging, DTB tooling.

**Keys are not bundled.** `sign-boot.py` expects `keys/verity.pk8` +
`keys/verity.x509.pem` next to `scripts/` (i.e. `boot-signing/keys/`). This is
the *publicly distributed* Android dev/test verity keypair that ships in the
well-known `Disable_Dm-Verity` zip — the PVG100 bootloader trusts it and boots
yellow-state. Grab it from that zip, or from the predecessor repo's `keys/`:

```bash
cp ~/Projects/android-pepito-pvg100-kernel-upgrade/keys/verity.{pk8,x509.pem} \
   boot-signing/keys/
```

(It is not a secret — every PVG100 owner uses the same pair — but bundling
key material in a repo is a deliberate choice, so it's left out by default.)
