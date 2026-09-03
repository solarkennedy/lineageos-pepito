# prebuilts/

Third-party binaries pinned here so the build server (an rsync mirror of this
repo) can reproduce a release without fetching anything at build time.

- `Magisk-v30.7.apk` — upstream Magisk release, used by
  `scripts/make-magisk-boot.sh` as the source of the x86-64 `magiskboot` /
  `magiskinit` / `magisk` binaries and `assets/boot_patch.sh`. Nothing is
  vendored into our tree; the APK is unpacked to a tmpdir per run.
  Magisk is GPLv3 — https://github.com/topjohnwu/Magisk
  Bumping this file changes the Magisk version shipped in the EDL bundle, so
  update `MAGISK_VERSION` in `release.sh` at the same time, and keep exactly
  one APK here — make-magisk-boot.sh refuses to guess between two.
  Minimum version is v30.7: earlier Magisk (v28.1 was tried) ships a libsepol
  that cannot parse our sepolicy — `avtab_read: more than one specifier` —
  after which init dies in SetupSelinux and the phone reboots to recovery in a
  loop. v30.7's changelog carries "[MagiskInit] Support Android 16 QPR2
  sepolicy format".

The APK itself is **not tracked** (`.gitignore`: `prebuilts/*.apk`) — it's an
upstream binary, not ours to vendor into a public repo. It lives in the working
tree only, and rsync carries it to the build server with the rest of this repo.
If a fresh clone is missing it, grab the release named in `release.sh`'s
`MAGISK_VERSION` from the upstream releases page and drop it here under the same
`Magisk-<version>.apk` name; without it `prepare-flash.sh` warns and skips
`boot-magisk.bin`, and `release.sh` then refuses to build the EDL bundle.
