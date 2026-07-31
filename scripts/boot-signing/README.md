# boot-signing

`verify-boot-sig.py` — inspect/verify a boot image's appended signature.
`sign-boot.py` — legacy key-based signer (superseded; kept for reference).

**The active fail-open graft signer moved into the device tree** so the Android
build can invoke it (it's referenced by
`device/xiaomi/mithorium-common/custom_bootimg.mk`, which grafts boot.img and
recovery.img at build time). Canonical location:

    device/xiaomi/mithorium-common/boot-signing/sign-boot-graft.py

`prepare-flash.sh` (EDL staging) uses that same in-tree copy.
