# ota2raw

Converts a pepito LineageOS release zip into the raw partition images that
`qdl` writes over EDL. One zip per flavor is published; it is an ordinary OTA
package with the EDL flashing kit added under `edl/`, and this program is the
step that turns its update payload back into flashable images:

| Output | Built from |
|---|---|
| `boot.bin`, `recovery.bin` | `boot.img` / `recovery.img`, zero-padded to the partition size |
| `system.bin`, `vendor.bin` | `<part>.new.dat.br` (brotli) written out per `<part>.transfer.list` |
| `config.bin` | zero-fill |

What to build and the SHA-256 each image must have come from
`edl/manifest.json` in the zip, written by `scripts/release.sh`. The release
script also runs this converter on the finished zip and requires the result to
be byte-identical to the build's own images (the target-files images the OTA
was generated from, desparsified with AOSP's `simg2img`), so a mismatch is
caught before anything is published.

Only full OTA zips can be converted. An incremental OTA patches blocks already
on the phone and is rejected.

## Use

    ota2raw                     # run from the edl/ folder of an extracted zip
    ota2raw lineage-....zip     # read the zip directly, write ./<zip name>-edl/
    ota2raw extracted-folder
      -o DIR                    # write the images to DIR

## Build

    ./build.sh <out-dir> [version]

Cross-compiles static binaries for linux x86_64/arm64, macOS arm64/x86_64 and
windows x86_64. Pure Go, CGO off. The only dependency, the
[andybalholm/brotli](https://github.com/andybalholm/brotli) decoder (MIT), is
vendored so the build needs no network.
