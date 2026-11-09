# Building LineageOS 24.0 for the PVG100

How to rebuild a release (or the live branches) from source. Written so a
person or an AI agent can follow it on a fresh build host. Paths are relative
to the Android tree root unless they say otherwise.

## Inputs that are not in git

| Input | Goes to | Where it comes from |
|---|---|---|
| Vendor blobs | `vendor/xiaomi/` | `proprietary_vendor_xiaomi`, branch `pepito-vendor`. **Private**, fetched over SSH by the manifest: you need read access and an SSH key on your GitHub account. No blobs, no build. |
| Release keyset | `vendor/lineage-priv/` (`keys/` incl. `keys.mk`, `keys-apex/`) | Held by the maintainers, never in any repo. Anyone else: generate your own with `scripts/generate-keys.sh` (written for 23.2; the same layout is used on 24.0). Builds signed with a different keyset will not install as updates over the published releases: phones need a clean flash. |
| PepitoLauncher2 key | `device/xiaomi/Mi8937/security/pepitolauncher2/pepitolauncher2.{pk8,x509.pem}` | Same as the keyset (or `development/tools/make_key pepitolauncher2 '/CN=pepitolauncher2'`). The build stops at analysis without it. |
| GApps payload (gapps flavor only) | `vendor/pepito-gapps/` | Google's binaries, never redistributed; see [GApps payload](#gapps-payload) below. |
| EDL inputs (`pvg100_firehose.elf`, `pvg100e_firehose.elf`, `rawprogram0.pvg100.xml`, `rawprogram0.pvg100e.xml`) | `flash-staging/` | The `edl/` folder of any published release zip. `release.sh` packs them into the zip's EDL kit, `flash-staging.sh` flashes with them. |
| Magisk v30.7 APK | `prebuilts/Magisk-v30.7.apk` in **this** repo | Upstream release (github.com/topjohnwu/Magisk); see [prebuilts/README.md](prebuilts/README.md). Only for `boot-magisk.bin` and packaging a release zip. |

Boot signing needs nothing: `device/xiaomi/mithorium-common/boot-signing/sign-boot-graft.py`
grafts the stock TCL signature block at build time, no key involved.

**Never commit key material anywhere.** `.gitignore` here explains the one
time a key nearly landed in this public repo.

### GApps payload

As used for 20261108. Four NikGapps **Android 16** packs dated 2026-02-22 (the
A16 payload is used on A17 on purpose, see `plans/PLAN-android17.md`), from the
nikgapps SourceForge project, `Releases/Android-16/22-Feb-2026` and its `Addons/`:

```
vendor/pepito-gapps/source/
  273129088  6f0eeb97bf930851c7bc3ce85c23baed51fe2184401ef6ac411becc701a15876  NikGapps-basic-arm64-16-20260222-signed.zip
    2663055  777b018db96768bf7a2afe74cc1c779642aec741bb241651b9dd7a0e62aad040  NikGapps-Addon-16-AndroidAuto-20260222-signed.zip
  171187726  ed8467cf0e569690e343b82ce472832dbd9596387e8b181ea4a81c56c1a7e9bf  NikGapps-Addon-16-GoogleSearch-20260222-signed.zip
   40601881  4ffb6029e4bbab0c1a2a1848b47dabe472eb1739068b0b44ca15ac7672747b6e  NikGapps-Addon-16-GoogleTTS-20260222-signed.zip
```

Plus two newer Google-signed APKs that replace what NikGapps ships (file name =
module name):

```
vendor/pepito-gapps/overrides/
  217107692  35f23040de6362a77103edb4b23825cfed7310ab6efe4d59310f817d79e6c1c2  PrebuiltGmsCoreVic.apk
             com.google.android.gms 26.11.36 (260400-892401869), versionCode 261136035
    9673475  9072f0f010132757f0efa5ad759269667ed2c982633204c01ba4e48c71eecee4  CarrierServices.apk
             com.google.android.ims carrierservices.android_20250826_00_RC00.phone, versionCode 31153903
```

If a mirror doesn't have those exact versions, pull them out of the published
20261108 gapps zip (the system image in the OTA payload; `tools/ota2raw`
extracts it). Then `scripts/extract-nikgapps.py vendor/pepito-gapps/source/NikGapps-*.zip`
writes `product/`, `system_ext/`, `gapps.mk` and `Android.bp` and applies
`overrides/`.

## Build recipe

### 1. Host

A standard LineageOS build host (Ubuntu 22.04/24.04 with the usual LineageOS
build packages, `repo`, `git-lfs`). About 350 GB of disk. RAM is what bites:
Soong analysis peaks around 31 GB, and A17's Kotlin/R8 steps OOM'd the 62 GB
build server until jobs were capped. `build-lineage24.sh` defaults to
`PEPITO_JOBS=14` and `NINJA_HIGHMEM_NUM_JOBS=3` for 62 GB; scale both down on
a smaller machine.

### 2. Source, pinned to exactly what 20261108 was built from

`manifests/snapshots/<date>.xml` in this repo is the whole tree flattened
to commit SHAs (all ~1,250 projects, upstream and forks) at each release.

```bash
git clone -b lineageos24.0 https://github.com/solarkennedy/lineageos-pepito.git ~/lineageos-pepito
mkdir ~/lineage-24 && cd ~/lineage-24
repo init -u https://github.com/LineageOS/android.git -b lineage-24.0 --git-lfs
cp ~/lineageos-pepito/manifests/snapshots/20261108.xml .repo/manifests/pepito-20261108.xml
repo init -m pepito-20261108.xml
repo sync -c -j8 --no-tags
ln -s ~/lineageos-pepito/scripts scripts
```

To follow the live branches instead (development), skip the snapshot and drop
`manifests/pepito.xml` into `.repo/local_manifests/`. Use one or the other: the
snapshot already contains the forks.

The release tag `pepito-24.0-20261108` exists on this repo and on every
fork, if you'd rather check out by tag.

### 3. Put the untracked inputs in place

```bash
# keys: vendor/lineage-priv/{keys,keys-apex}/ and the PepitoLauncher2 pair, see above
unzip -j lineage-24.0-20261108-UNOFFICIAL-Mi8937.zip 'edl/*_firehose.elf' 'edl/rawprogram0.*.xml' -d flash-staging/
# gapps flavor only: vendor/pepito-gapps/, see GApps payload above
```

### 4. Build

The release builds ran with these settings (`release-all.sh` → `build-lineage24-remotely.sh`
→ `build-lineage24.sh`):

```bash
export LINEAGE_ROOT=$PWD
export LINEAGE_BUILD_DATE=20261108          # stamps fingerprint + zip name
export TARGET_PEPITO_KEYMASTER_DHSECAPP_DIAGNOSTIC=true
export TARGET_PEPITO_HARDWARE_KEYMASTER_DIAGNOSTIC=true
./scripts/build-lineage24.sh                # vanilla: lineage_Mi8937 cp2a userdebug, mka bacon
./scripts/build-lineage24.sh --gapps        # gapps: lineage_Mi8937_gapps, WITH_GMS=true, RELEASE_TYPE=SNAPSHOT
```

The two keymaster env flags are always set by the remote wrapper, so a build
without them is not the shipped configuration.

The OTA zip lands in `out/target/product/Mi8937/`. One `out/` per flavor at a
time: build, package, then build the other.

### 5. Package and flash images

- `scripts/prepare-flash.sh` stages the EDL images (signed boot/recovery,
  raw system/vendor, zeroed `config.bin`) in `flash-staging/`.
- `scripts/release.sh out/target/product/Mi8937/lineage-24.0-*.zip --package-only`
  makes the published-style zip (OTA zip + README + `edl/` kit, re-signed with the
  release key) and verifies it. It reads the EDL inputs and Magisk APK, so run
  `prepare-flash.sh` first. Set `LINEAGE_ROOT` and `REPO_ROOT` (this repo);
  the defaults are `/home/kyle/...`. Without `--package-only` it publishes to
  GitHub and updates the OTA feed, so leave that flag on unless you mean to release.
- `scripts/flash-staging.sh` flashes `flash-staging/` over EDL with `qdl`.
- `scripts/README.md` describes every script. `build-lineage24-remotely.sh` and
  `release-all.sh` wrap all this for a laptop + separate build server and
  hard-code that setup (IP, paths, phone roster); read them for the sequence,
  don't run them as-is.

### 6. Checking it matches

Android builds aren't byte-reproducible (timestamps, signing), so compare
behaviour and identity, not the zip hash: the fingerprint
(`ro.build.fingerprint`), `META-INF/com/android/metadata` in the OTA zip, and
the per-project heads (`repo forall -c 'git rev-parse HEAD'` against the
snapshot). `release.sh` also checks that `ota2raw` rebuilds byte-identical images
from the zip and that no framework class is missing an abstract-method
implementation (`scripts/check-abstract-impls.py`). That second check caught the
withdrawn 20261101 gapps build.

## Where the knowledge lives

- [AGENTS.md](AGENTS.md) is the orientation file Claude reads first.
- `plans/PLAN-android17.md` is the live plan for this line; `plans/PLAN-*.md`
  hold the investigations (modem, IMS, sensors...).
- `REBASE.md` + `scripts/upstream.py`: the monthly rebase onto upstream lineage-24.0.
- `CHANGELOG.md`: what each release changed.

