# Building LineageOS 23.2 for pepito

> **Status: recipe skeleton.** Steps marked _TBD_ depend on the fork remotes
> and release signing keys being finalized (tracked in the source tree's
> `PLAN-release.md`, Gate 0 / Phases 6–8). Until then this documents the
> intended reproducible flow; the working bench flow lives in the source
> tree's `BUILD.md` + `scripts/build-lineage23.sh`.

## 1. Host setup

Standard LineageOS 23.2 build host (Ubuntu 22.04+ works):
<https://wiki.lineageos.org/devices/> → any 23.2 device → "Build for yourself".
~350 GB disk, 32 GB RAM recommended.

## 2. Sync the tree

```bash
mkdir lineage-23 && cd lineage-23
repo init -u https://github.com/LineageOS/android.git -b lineage-23.2 --git-lfs
mkdir -p .repo/local_manifests
curl -o .repo/local_manifests/pepito.xml \
  https://raw.githubusercontent.com/TBD/lineageos-pepito/main/manifests/pepito.xml   # TBD: final URL
repo sync -j8
```

The local manifest pins every repo carrying pepito changes (kernel, device
trees, recovery, the QS-slider framework patches, vendor blobs). See
[manifests/pepito.xml](manifests/pepito.xml) — _TBD: currently still points at
the LineageOS upstreams; it will be repointed at the pepito forks + branches
when they are pushed._

## 3. Vendor blobs

_TBD: final packaging model — either a `proprietary_vendor_xiaomi` repo in the
manifest (nothing to do), or `extract-files.py` against a documented stock
Palm AML0 + Mi8937-nightly source._

## 4. Build

```bash
source build/envsetup.sh
lunch lineage_Mi8937-bp4a-userdebug
m bacon        # or: m, for the full image set
```

The pepito variant is runtime-detected (`ro.vendor.xiaomi.device=pepito` via
libinit); one `lineage_Mi8937` build serves the whole device family.

For **release** builds: sign with a dedicated keyset, not test-keys — _TBD:
key generation + `sign_target_files_apks`/`ota_from_target_files` steps
(PLAN-release.md Phase 8)._

## 5. Flash

- **Recovery sideload** (planned release path): boot LineageOS recovery,
  `adb sideload <build>.zip`. _TBD: recovery image install instructions for a
  stock PVG100 (EDL-based first-time unlock/flash)._
- **EDL image set** (current bench path): _TBD: document the EDL loader +
  partition set._

First boot with a userdata wipe is required coming from stock (FBE).
