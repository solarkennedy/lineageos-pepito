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

**Keys:** `boot-signing/keys/` bundles `verity.pk8` + `verity.x509.pem` —
the **standard AOSP development verity keypair** (self-signed,
`CN=Android/O=Android`, RSA-2048, serial `970F983909AA8949`, sha256
fingerprint `8A:D1:27:AB:…:7B:3B:86`), committed publicly to AOSP in the
Lollipop era and also distributed in the well-known `Disable_Dm-Verity` zip.
**It is not a secret** — the private half is public, every PVG100 owner uses
the same pair, and it is bundled here deliberately so the signing pipeline
runs out of the box.

Trust model: the PVG100 LK bootloader (AVBv1, `BOOT.BF.3.3 boot_verifier`)
boots images signed with this key in **yellow state** (warning screen, then
boots). Green state would require TCL's production key, which nobody outside
TCL has. Consequence: there is no meaningful secure boot on this device —
anyone can sign a bootable image with a public key.
