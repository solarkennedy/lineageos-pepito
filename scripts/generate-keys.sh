#!/usr/bin/env bash
#
# Generate the pepito (PVG100) ROM release keyset — LineageOS 23 / Android 16.
# Mirrors wiki.lineageos.org/signing_builds, but targets vendor/lineage-priv/keys
# (this tree's keys.mk location, per vendor/lineage/config/common.mk) instead of
# ~/.android-certs.
#
# Run ONCE, from anywhere. Keys land in vendor/lineage-priv/keys/. That dir is a
# PRIVATE, NEVER-PUSHED repo: the .pk8/.x509.pem/.pem material must never be
# committed to any public remote. Only keys.mk (wiring) is safe to track, and
# only in a private mirror.
#
# make_key prompts for a password per key; blank = unencrypted. This script is
# built for the blank-password path (make_key exits 1 on a blank password, which
# is expected and tolerated). For APEX keys you'll be prompted TWICE each.
#
# What the keys unlock:
#   1. Build-time app signing (via keys.mk): flips test-keys -> release-keys.
#      Sufficient for a `lineage_Mi8937-user` build + basic-integrity smoke test.
#   2. Full re-sign incl. APEXes (via sign_target_files_apks): needed for the
#      real signed OTA/target-files release. Command template printed at the end.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KEYS="$ROOT/vendor/lineage-priv/keys"
# APEX keys MUST NOT live in $KEYS (the DefaultAppCertificate dir): if they do,
# Soong signs APEX payloads with them but leaves apex_pubkey at the module
# default -> half-override -> apexd "public key doesn't match the pre-installed
# one" -> boot loop. They belong in a sibling dir, consumed only by the
# post-build sign_target_files_apks --extra_apks step.
APEX_KEYS="$ROOT/vendor/lineage-priv/keys-apex"
MAKE_KEY="$ROOT/development/tools/make_key"
MAKE_KEY_4096="$APEX_KEYS/make_key"   # 4096-bit copy for APEX keys

# Edit if you want a real DN. CN here is per-key (set in the loops). Keep the
# rest stable forever once you ship — changing it breaks the OTA update chain.
SUBJECT_BASE='/C=US/ST=/L=/O=/OU=/emailAddress=kyle@cascade.family'

mkdir -p "$KEYS"

gen_key() {  # $1 = cert basename, $2 = make_key binary, $3 = CN
    local cert="$1" mk="$2" cn="$3"
    if [ -f "$KEYS/$cert.pk8" ]; then
        echo "    skip $cert (already exists)"; return 0
    fi
    echo "    generating $cert"
    # make_key exits 1 on a blank password (final encrypt-test is false) — tolerate.
    "$mk" "$KEYS/$cert" "/C=US/ST=/L=/O=/OU=/CN=$cn/emailAddress=kyle@cascade.family" || true
    if [ ! -f "$KEYS/$cert.pk8" ]; then
        echo "ERROR: $cert.pk8 was not created — aborting." >&2; exit 1
    fi
}

gen_key_dir() {  # $1 = target dir, $2 = cert basename, $3 = make_key binary, $4 = CN
    local dir="$1" cert="$2" mk="$3" cn="$4"
    if [ -f "$dir/$cert.pk8" ]; then
        echo "    skip $cert (already exists)"; return 0
    fi
    echo "    generating $cert"
    "$mk" "$dir/$cert" "/C=US/ST=/L=/O=/OU=/CN=$cn/emailAddress=kyle@cascade.family" || true
    if [ ! -f "$dir/$cert.pk8" ]; then
        echo "ERROR: $cert.pk8 was not created — aborting." >&2; exit 1
    fi
}

echo "==> Standard platform keyset (2048-bit)"
# Superset of what this tree references — generating unused certs is harmless;
# a MISSING referenced cert breaks the build. testkey/testcert/mediashell-release
# ARE required: system/sepolicy keys.conf resolves EVERY cert tag (incl @TESTKEY)
# relative to DEFAULT_SYSTEM_DEV_CERTIFICATE, which is now this dir.
for cert in bluetooth cyngn-app media mediashell-release networkstack nfc platform \
            releasekey sdk_sandbox shared testcert testkey verity; do
    gen_key "$cert" "$MAKE_KEY" pepito
done

echo "==> AVB (verified boot) key"
if [ ! -f "$KEYS/avb.pem" ]; then
    openssl genrsa -out "$KEYS/avb.pem" 4096
    if command -v avbtool >/dev/null 2>&1; then
        avbtool extract_public_key --key "$KEYS/avb.pem" --output "$KEYS/avb_pkmd.bin"
    else
        echo "    WARN: avbtool not on PATH — run 'avbtool extract_public_key' later for avb_pkmd.bin"
    fi
else
    echo "    skip avb (already exists)"
fi

echo "==> APEX keys (4096-bit — LineageOS 19.1+ requires SHA256_RSA4096)"
echo "    (into $APEX_KEYS — NOT the build-time cert dir; see note above)"
mkdir -p "$APEX_KEYS"
if [ ! -f "$MAKE_KEY_4096" ]; then
    cp "$MAKE_KEY" "$MAKE_KEY_4096"
    sed -i 's|2048|4096|g' "$MAKE_KEY_4096"
fi
APEXES="
com.android.adbd com.android.adservices com.android.adservices.api
com.android.appsearch com.android.art com.android.bluetooth com.android.bt
com.android.btservices com.android.cellbroadcast com.android.compos
com.android.configinfrastructure com.android.connectivity.resources
com.android.conscrypt com.android.crashrecovery com.android.devicelock
com.android.extservices com.android.graphics.pdf com.android.hardware.authsecret
com.android.hardware.biometrics.face.virtual
com.android.hardware.biometrics.fingerprint.virtual com.android.hardware.boot
com.android.hardware.cas com.android.hardware.contexthub
com.android.hardware.dumpstate com.android.hardware.gatekeeper.nonsecure
com.android.hardware.neuralnetworks com.android.hardware.power
com.android.hardware.rebootescrow com.android.hardware.thermal
com.android.hardware.threadnetwork com.android.hardware.uwb
com.android.hardware.vibrator com.android.hardware.wifi com.android.healthfitness
com.android.hotspot2.osulogin com.android.i18n com.android.ipsec com.android.media
com.android.media.swcodec com.android.mediaprovider com.android.nearby.halfsheet
com.android.networkstack.tethering com.android.neuralnetworks
com.android.nfcservices com.android.npumanager com.android.ondevicepersonalization
com.android.os.statsd com.android.permission com.android.profiling
com.android.resolv com.android.rkpd com.android.runtime
com.android.safetycenter.resources com.android.scheduling com.android.sdkext
com.android.support.apexer com.android.telephony com.android.telephonycore
com.android.telephonymodules com.android.tethering com.android.tzdata
com.android.uprobestats com.android.uwb com.android.uwb.resources com.android.virt
com.android.vndk.current com.android.vndk.current.on_vendor com.android.webapp
com.android.wifi com.android.wifi.dialog com.android.wifi.resources
com.google.pixel.camera.hal com.google.pixel.vibrator.hal com.qorvo.uwb
"
for apex in $APEXES; do
    gen_key_dir "$APEX_KEYS" "$apex" "$MAKE_KEY_4096" "$apex"
    [ -f "$APEX_KEYS/$apex.pem" ] || openssl pkcs8 -in "$APEX_KEYS/$apex.pk8" -inform DER -nocrypt -out "$APEX_KEYS/$apex.pem"
done

echo "==> Wiring keys.mk (created only now that keys exist)"
if [ ! -f "$KEYS/keys.mk" ]; then
    cat > "$KEYS/keys.mk" <<'EOF'
# Auto-created by scripts/generate-keys.sh. Flips test-keys -> release-keys.
PRODUCT_DEFAULT_DEV_CERTIFICATE := vendor/lineage-priv/keys/releasekey
PRODUCT_OTA_PUBLIC_KEYS := vendor/lineage-priv/keys/releasekey
EOF
    echo "    wrote $KEYS/keys.mk"
else
    echo "    skip keys.mk (already exists)"
fi

cat <<'EOF'

==> Keyset complete: standard certs + AVB + APEX keys + keys.mk.

  * Basic-integrity smoke test: build `lineage_Mi8937-user` now. keys.mk signs
    apps with your release keys -> ro.build.tags=release-keys.

  * Fully-signed release (OTA/target-files, re-signs APEXes too):
      breakfast Mi8937 && mka target-files-package otatools
      croot
      sign_target_files_apks -o -d vendor/lineage-priv/keys \
        --extra_apks <apexapk>.apk=vendor/lineage-priv/keys/releasekey ... \
        --extra_apks <apex>.apex=vendor/lineage-priv/keys-apex/<apex> ... \
        --extra_apex_payload_key <apex>.apex=vendor/lineage-priv/keys-apex/<apex>.pem ... \
        $OUT/obj/PACKAGING/target_files_intermediates/*-target_files-*.zip \
        signed-target_files.zip
    (Full --extra_apks list is on wiki.lineageos.org/signing_builds. APEX certs
    live in keys-apex/ NOT keys/, so a plain build can't half-sign APEXes and
    bootloop; sign_target_files re-signs payload+pubkey together, consistently.)
EOF
