# Extracting blobs from a nightly vendor.img

When source-built HALs need a proprietary library that isn't in the tree, the
authoritative source is the official LineageOS nightly for the device. Below
is the workflow that was hard-won during the qseecomd/keymaster bring-up.

> Each step has a Watch-out — read those first if you're skimming.

> **⚠️ 2026-06-23 — blob regressions from re-extraction / manual swaps.** Two
> boot-breaking regressions traced to a working vendor blob being replaced with a
> **stock Android-8** version that the 4.19 stack can't use:
> - GPU CP microcode `a530_pm4.fw`/`a530_pfp.fw` swapped to the AML0-stock ucode →
>   "CP init failed to idle" → SurfaceFlinger crash loop. Fixed by restoring the
>   newer `out/` ucode; broken copies kept as `*.stock-3.18-bak`. (`PLAN-surfaceflinger.md`)
> - (Kernel-side analog: the RPMB **node type** mismatch with the stock
>   qseecomd/librpmb; fixed in-kernel — `PLAN-gatekeeper.md`.)
>
> Lesson: do not let extract-files or a stock-vendor dump overwrite blobs that
> were deliberately sourced newer for the 4.19/A16 stack. Pin/guard the GPU ucode
> (and any other 4.19-specific blob) so a re-extraction can't downgrade it.
>
> **Incomplete blob closure (2026-06-23):** on the booted build these daemons fail
> with `CANNOT LINK EXECUTABLE`: `rmt_storage` (`libCheckTunning.so`), `pm-service`
> / `tftp_server` (`libsmemlog.so` via `libqmi_csi.so`), `ATFWD-daemon`
> (`vendor.qti.hardware.radio.atcmdfwd@1.0_vendor.so`), `mm-qcamera-daemon`
> (`libmmcamera2_mct.so`). Walk these DT_NEEDED closures and add the missing libs.

---

## 1. Mount the nightly vendor partition

The nightly ships a sparse vendor.img inside the OTA zip. Unsparse and mount:

```bash
# One-time: extract vendor.img from the OTA zip
unzip lineage-23.2-<date>-nightly-Mi8937-signed.zip vendor.img -d /tmp/
simg2img /tmp/vendor.img /tmp/vendor-nightly.img
sudo mkdir -p /mnt/vendor-nightly
sudo mount -o ro,loop /tmp/vendor-nightly.img /mnt/vendor-nightly
```

**Watch-out:** `/vendor/bin/` is mode 710 (root:2000). A non-root `ls`
returns nothing without an error, which looks like "directory is empty."
Always inspect with sudo:

```bash
sudo ls -la /mnt/vendor-nightly/bin/        # NOT ls without sudo
sudo find /mnt/vendor-nightly -name 'lib*.so'
```

This trap claimed multiple sessions of debugging before being noticed —
one earlier session concluded "qseecomd is missing from the nightly"
when in fact it was there the whole time, just invisible to a non-root
listing.

---

## 2. Find the right library set (transitive closure walk)

A blob's `DT_NEEDED` only shows the first level of dependencies. The
recursive closure must be extracted, or the vendor linker hits "library X
not found" at startup and the service exits status 1 with no other
visible error. Walk `readelf` until the set is stable:

```bash
walk_needed() {
  readelf -d "$1" 2>/dev/null | grep NEEDED | awk '{print $5}' | tr -d '[]'
}

# Iteration 1: direct deps
walk_needed /mnt/vendor-nightly/bin/qseecomd

# Iteration 2+: for each lib added, repeat
for lib in libdrmfs.so libdrmtime.so librpmb.so ...; do
  walk_needed /mnt/vendor-nightly/lib64/$lib
done
```

Repeat until no new names appear. **Skip** names that resolve via:

- Standard system libs (`libc`, `libm`, `libdl`, `libcutils`, `libutils`,
  `liblog`, `libc++`, `libbase`, `libhidlbase`, `libbinder`, `libhardware`)
- AOSP libs built `vendor_available: true` (check `external/`)
- Anything under `vendor/qcom/opensource/` or `hardware/qcom-caf/`
  (built from source, not a prebuilt)

For everything else, extract.

**Watch-out:** sometimes a transitive dep is *also* something built from
source in the tree (`vendor.display.config@1.0`, `libdisplayconfig.qti`,
`libxml2`). Extracting those as prebuilts causes packaging conflicts
(see §6).

---

## 3. Copy the blobs into the proprietary tree

```bash
DST=/home/kyle/android/lineage-23/vendor/xiaomi/Mi8937/proprietary/vendor/lib64
sudo cp /mnt/vendor-nightly/lib64/libNAME.so "$DST/"
sudo chown -R $USER:$USER "$DST/"
```

Binaries go to `proprietary/vendor/bin/`, libs to
`proprietary/vendor/lib64/` (or `lib/` for 32-bit — but most modern
vendor stacks are 64-bit only).

**Watch-out:** mithorium-common's proprietary tree at
`vendor/xiaomi/mithorium-common/proprietary/` is separate from Mi8937's
at `vendor/xiaomi/Mi8937/proprietary/`. Put device-specific blobs in
Mi8937; put blobs shared with the whole MSM8937 family (Mi8917, tiare,
Mi439, etc. — primarily GPU/Adreno) in mithorium-common.

---

## 4. Add entries to `proprietary-files.txt`

Format: `path[;DISABLE_DEPS]` — the leading `-` marks the blob as
required (extraction must succeed) and `DISABLE_DEPS` tells the build
to skip `check_elf_files` validation (which would otherwise fail on the
random ABI-private deps we've intentionally skipped).

```text
# Keystore — from olive
-vendor/lib64/hw/keystore.msm8937.so;DISABLE_DEPS

# QSEE userspace stack — from nightly
-vendor/bin/qseecomd;DISABLE_DEPS
-vendor/lib64/libQSEEComAPI.so;DISABLE_DEPS
# ... etc
```

Group by purpose; add a comment explaining what the set unlocks.

Mi8937 uses a single `proprietary-files.txt`. Mithorium-common uses
three: `proprietary-files-misc.txt`, `proprietary-files-qc-sys.txt`,
`proprietary-files-qc-vndr.txt` — each scoped to one category. Add your
entry to whichever fits.

---

## 5. Regenerate the makefiles

### 5a. Two extractor scripts exist — use the Python one

Every device tree ships **both** `extract-files.py` (Python, Soong-aware)
and `extract-files.sh` (bash, legacy). They produce different output and
the tree's tooling expects Python:

|                       | Python (`.py`)                                                | Bash (`.sh`)                                                               |
|-----------------------|---------------------------------------------------------------|----------------------------------------------------------------------------|
| Style                 | Soong modules                                                 | Legacy make rules                                                          |
| `*-vendor.mk`         | `PRODUCT_PACKAGES += libfoo \`                                | `PRODUCT_COPY_FILES += $(LOCAL_PATH)/x:$(TARGET_COPY_OUT_VENDOR)/x \`      |
| `Android.bp`          | Full `cc_prebuilt_library_shared { ... }` per blob            | Empty `soong_namespace` stub only                                          |
| ABI checks            | Yes (opt out per blob with `;DISABLE_DEPS`)                   | No                                                                         |
| Module ownership      | Yes (Soong tracks every blob)                                 | No (blobs are opaque file copies)                                          |
| **Strict mode**       | **Refuses to run if any listed blob is missing on disk**      | Silently skips missing blobs                                               |
| Status for this tree  | **Canonical** — use this                                      | Legacy fallback                                                            |

If you see `Android.bp` shrink to ~8 lines after running an extractor,
you used the bash script by mistake.

### 5b. Four extract-files.py paths in the tree — only two are runnable

| Path                                                                       | What it is                                                | When to run                                                                                  |
|----------------------------------------------------------------------------|-----------------------------------------------------------|----------------------------------------------------------------------------------------------|
| `device/xiaomi/Mi8937/extract-files.py`                                    | Mi8937 device extractor                                   | After editing `device/xiaomi/Mi8937/proprietary-files.txt`                                   |
| `device/xiaomi/mithorium-common/extract-files.py`                          | Common (shared with Mi8917, Mi439, tiare)                 | After editing `device/xiaomi/mithorium-common/proprietary-files-{misc,qc-sys,qc-vndr}.txt`   |
| `tools/extract-utils/templates/single-device/extract-files.py`             | TEMPLATE — don't run                                      | n/a                                                                                          |
| `tools/extract-utils/templates/multi-device/device/extract-files.py`       | TEMPLATE — don't run                                      | n/a                                                                                          |

Output paths:

```
device/xiaomi/Mi8937/extract-files.py
  → vendor/xiaomi/Mi8937/{Android.bp, Mi8937-vendor.mk}
device/xiaomi/mithorium-common/extract-files.py
  → vendor/xiaomi/mithorium-common/{Android.bp, mithorium-common-vendor.mk}
```

### 5c. The actual command

**Always pass `-n -m`**: `-n` (`--no-cleanup`) preserves blobs you copied
in by hand instead of re-extracting them; `-m` regenerates `*-vendor.mk`
and `Android.bp`.

```bash
# Mi8937-specific blobs (qseecomd, keystore, sensors, etc.)
cd /home/kyle/android/lineage-23/device/xiaomi/Mi8937
PYTHONPATH=../../../tools/extract-utils python3 \
  extract-files.py -n -m /mnt/vendor-nightly

# Common blobs (GPU/Adreno, generic Qualcomm)
cd /home/kyle/android/lineage-23/device/xiaomi/mithorium-common
PYTHONPATH=../../../tools/extract-utils python3 \
  extract-files.py -n -m /mnt/vendor-nightly
```

Verify regeneration: check `vendor/xiaomi/Mi8937/Mi8937-vendor.mk` for
new entries under `PRODUCT_PACKAGES`, and
`vendor/xiaomi/Mi8937/Android.bp` for
`cc_prebuilt_library_shared { name: "libNAME", ... }` blocks.

### 5d. Watch-out: the Python extractor fails hard on missing blobs

If `proprietary-files-*.txt` lists a path that doesn't exist on disk in
`proprietary/`, the Python extractor crashes with:

```
FileNotFoundError: [Errno 2] No such file or directory:
  '.../proprietary/vendor/lib64/SOMELIB.so'
```

It computes ABI info for every listed module — that requires reading the
ELF — so missing files are fatal. Fix by either extracting the missing
blob from the nightly, or removing the entry from `proprietary-files-*.txt`.

This is the main reason `mithorium-common` is currently stuck in
legacy-bash-extractor mode (see §9).

---

## 6. Resolve packaging conflicts

If a module is already built from source elsewhere in the tree, you'll
see:

```
error: ...: module "X" variant "..." (created by module "X_interface"):
   partition is different: system(X) != vendor(prebuilt_X)
```

Examples we hit: `vendor.display.config@1.0/@2.0`,
`libdisplayconfig.qti`, `libxml2`.

Fix: drop those entries from `proprietary-files.txt`, delete the copied
blob from `proprietary/vendor/lib*/`, and re-run extract-files. The
source build provides the in-vendor variant correctly.

Also drop blobs that **mithorium-common already provides as in-tree source**
(currently: `init.qti.qseecomd.sh` under `mithorium-common/rootdir/bin/`,
which has a bounded retry loop — the nightly version is unbounded and
worse).

---

## 7. Common pitfalls

- **Recovery linker is not the boot linker.** Running a vendor binary
  from a recovery shell produces misleading "library not found" errors
  because recovery lacks the full VNDK and linkerconfig. Mount vendor
  at `/vendor` (not `/v` or `/tmp/x`) so at least the namespace
  heuristic fires correctly — and treat the first resolution layer's
  error as the ground truth, not anything past it.

- **stdio_to_kmsg as a last-resort log channel.** Init services close
  stdout/stderr by default; vendor binaries' ALOGE goes to logcat,
  which is invisible if the boot doesn't reach a usable adb. Add
  `stdio_to_kmsg` to the service definition (next to `class core`),
  rebuild `vendor.img`, reflash — the first failure prints to serial.
  Remove once you've found the cause.

- **ABI mismatch from different vendor revisions.** Blobs lifted from
  one device (e.g., olive) often work on a sibling SoC (Mi8937 family)
  but not always. If a blob loads cleanly but the service still
  aborts, cross-check the lib version against the nightly's version
  for *this* device first — that's the surest match.

- **Don't extract `init.qti.qseecomd.sh` (or similar wrapper scripts)
  if mithorium-common already has it under `rootdir/bin/`** — the
  tree version has bounded timeouts; the nightly version is unbounded
  and conflicts on install path.

- **`adb` is only available after `on boot` runs**, which is *after*
  `on post-fs-data`. If a service in post-fs-data hangs (like
  `vdc keymaster earlyBootEnded` did), you'll never have adb during
  that boot. Use serial console, recovery shell, or `stdio_to_kmsg`
  to make progress.

---

## 8. Quick reference: the command sequence we use

```bash
# Setup (once per session)
sudo mount -o ro,loop /tmp/vendor-nightly.img /mnt/vendor-nightly

# Inventory (with sudo — see §1)
sudo ls /mnt/vendor-nightly/bin/
sudo readelf -d /mnt/vendor-nightly/bin/qseecomd | grep NEEDED

# Copy
DST=vendor/xiaomi/Mi8937/proprietary/vendor
sudo cp /mnt/vendor-nightly/bin/qseecomd $DST/bin/
sudo cp /mnt/vendor-nightly/lib64/lib{QSEEComAPI,drmfs,...}.so $DST/lib64/
sudo chown -R $USER:$USER $DST

# Edit device/xiaomi/Mi8937/proprietary-files.txt by hand, then regen:
cd device/xiaomi/Mi8937
PYTHONPATH=../../../tools/extract-utils python3 \
  extract-files.py -n -m /mnt/vendor-nightly

# Verify
grep qseecomd ../../../vendor/xiaomi/Mi8937/Mi8937-vendor.mk

# Build + flash (vendor only)
cd ../../..
mka vendorimage
fastboot flash vendor out/target/product/Mi8937/vendor.img
fastboot reboot

# Teardown
sudo umount /mnt/vendor-nightly
```

---

## 9. Current state of `mithorium-common` (legacy-mode, TODO)

`vendor/xiaomi/mithorium-common/` is currently in **legacy bash-extractor
state**: `mithorium-common-vendor.mk` uses `PRODUCT_COPY_FILES` instead
of `PRODUCT_PACKAGES`, and `Android.bp` is the empty `soong_namespace`
stub. This is intentional-by-necessity:

- `proprietary-files-misc.txt` + `proprietary-files-qc-sys.txt` +
  `proprietary-files-qc-vndr.txt` list **hundreds** of blob entries
  that have never been extracted into `proprietary/`. They're
  aspirational — copied from a reference device tree but never
  populated.
- The Python extractor crashes on the first missing file (§5d), so
  it can't be used until the lists are trimmed to match what's on
  disk.
- The bash extractor silently skips the missing entries, so it
  produces a working `*-vendor.mk` covering only the GPU/EGL blobs
  that *do* exist.

The current state is functional — the GPU blobs get installed via
`PRODUCT_COPY_FILES`, Mi8937's `namespace_imports` still resolves
against the empty `soong_namespace`. But it's not the long-term
shape.

**Cleanup TODO** (not blocking anything):

1. Walk `proprietary-files-{misc,qc-sys,qc-vndr}.txt` line by line.
2. For each entry, check if the file exists in
   `vendor/xiaomi/mithorium-common/proprietary/`.
3. Comment out (or remove) any entry whose blob doesn't exist.
4. Re-run the Python extractor; it should now succeed and produce
   Soong-style output.
5. Optionally extract the formerly-missing blobs from the nightly
   if any are actually needed by something.
