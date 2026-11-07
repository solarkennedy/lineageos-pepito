#!/usr/bin/env bash
# Put a VNC server on a bench unit: droidVNC-NG (F-Droid, GPLv2), screen via
# MediaProjection, input via its accessibility service, started on boot. Nobody
# needs to be at the phone: root adb grants everything the app would ask for.
#
# Usage:
#   ./setup-vnc.sh dut1             # install (if needed), configure, start
#   ./setup-vnc.sh dut1 --stop      # stop the server
#   ./setup-vnc.sh dut1 --status    # installed? listening? which address?
#
# Connect: vncviewer <phone's Wi-Fi IP>:5900 (password from vnc.conf), or over
# USB when the LAN can't reach it:
#   adb -s <serial> forward tcp:5901 tcp:5900 && vncviewer localhost:5901
#
# CREDENTIALS come from ~/.config/pepito/vnc.conf (never committed), created on
# first run with random values, shell syntax:
#   VNC_PASSWORD='...'      # VNC auth is DES: only the first 8 characters count
#   VNC_ACCESS_KEY='...'    # droidVNC-NG's key for its start/stop intents
#   VNC_PORT=5900
#
# APK: $PEPITO_APKS (default ~/Projects/apks)/net.christianbeier.droidvnc_ng_*.apk,
# fetched from f-droid.org when there is none.
#
# What it sets, all of it what the app's own permission screens would:
#   - defaults.json in the app's external files dir: port, password, access key,
#     start on boot. The app reads it for any preference it hasn't stored yet.
#   - POST_NOTIFICATIONS granted (its foreground-service notification).
#   - appop PROJECT_MEDIA allow: MediaProjection starts with no consent dialog,
#     also on boot.
#   - appop SYSTEM_ALERT_WINDOW allow (it uses it to start from the background).
#   - its InputService added to enabled_accessibility_services (pointer + keys).
#   - doze whitelist, so the server isn't frozen with the screen off.
# Then ACTION_START with the access key, port and password as intent extras.

set -euo pipefail

UNIT=""
MODE=setup
PKG=net.christianbeier.droidvnc_ng
FDROID_VC=67        # 2.22.2; bump when F-Droid moves (api/v1/packages/$PKG)
APKS=${PEPITO_APKS:-$HOME/Projects/apks}
VNC_CONF=${PEPITO_VNC_CONF:-$HOME/.config/pepito/vnc.conf}

die() { echo "ERROR: $*" >&2; exit 1; }
say() { echo "== $*"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --stop)    MODE=stop ;;
        --status)  MODE=status ;;
        -h|--help) sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)        die "unknown option $1 (try --help)" ;;
        *)         UNIT=$1 ;;
    esac
    shift
done
[[ -n "$UNIT" ]] || die "which unit? (nick, serial or IMEI; there is deliberately no default)"

# Resolve nick/serial/IMEI → nick + serial via the roster (same rules as setup-phone.sh).
UNITS_CONF=${PEPITO_UNITS:-$HOME/.config/pepito/units.conf}
ROW=""
[[ -f "$UNITS_CONF" ]] && ROW=$(awk -v w="$UNIT" '!/^#/ && NF>=6 && !/^DAILY=/ && ($1==w || $2==w || $3==w){print; exit}' "$UNITS_CONF")
if [[ -n "$ROW" ]]; then
    read -r NICK SERIAL _ <<<"$ROW"
    [[ "$SERIAL" != "-" ]] || die "$NICK has no serial in $UNITS_CONF"
else
    [[ "$UNIT" =~ ^[0-9A-Za-z]{6,}$ ]] || die "'$UNIT' is not in $UNITS_CONF and doesn't look like a serial"
    NICK=$UNIT SERIAL=$UNIT
fi
echo "Target: $NICK ($SERIAL)"

dadb() { adb -s "$SERIAL" "$@" </dev/null; }
sh_() { dadb shell "$@" | tr -d '\r'; }

[[ "$(adb -s "$SERIAL" get-state 2>/dev/null)" == device ]] || die "$NICK is not on adb"
[[ "$(sh_ getprop ro.serialno)" == "$SERIAL" ]] || die "adb -s $SERIAL answered as another phone?!"

wifi_ip() { sh_ ip -4 addr show wlan0 2>/dev/null | awk '/inet /{sub(/\/.*/,"",$2); print $2; exit}'; }
listening() { sh_ "ss -ltn 2>/dev/null" | grep -q ":${VNC_PORT:-5900} "; }

if [[ ! -f "$VNC_CONF" ]]; then
    [[ $MODE == setup ]] || die "no $VNC_CONF yet (run without --stop/--status first)"
    rnd() { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$1"; }
    (umask 077; printf "# droidVNC-NG on bench units (setup-vnc.sh). Never committed.\nVNC_PASSWORD='%s'\nVNC_ACCESS_KEY='%s'\nVNC_PORT=5900\n" \
        "$(rnd 8)" "$(rnd 16)" >"$VNC_CONF")
    say "wrote new credentials to $VNC_CONF"
fi
# shellcheck source=/dev/null
. "$VNC_CONF"
: "${VNC_PASSWORD:?missing in $VNC_CONF}" "${VNC_ACCESS_KEY:?missing in $VNC_CONF}"
VNC_PORT=${VNC_PORT:-5900}

case $MODE in
status)
    sh_ pm path "$PKG" >/dev/null 2>&1 && echo "installed: $(sh_ dumpsys package "$PKG" | awk -F= '/versionName/{print $2; exit}')" || echo "installed: no"
    echo "accessibility: $(sh_ settings get secure enabled_accessibility_services)"
    echo "PROJECT_MEDIA: $(sh_ appops get "$PKG" PROJECT_MEDIA 2>/dev/null)"
    listening && echo "listening: yes, ${VNC_PORT}" || echo "listening: no"
    echo "wlan0: $(wifi_ip || true)"
    exit 0 ;;
stop)
    sh_ am start-foreground-service -n "$PKG/.MainService" -a "$PKG.ACTION_STOP" \
        --es "$PKG.EXTRA_ACCESS_KEY" "$VNC_ACCESS_KEY" >/dev/null
    say "stopped"
    exit 0 ;;
esac

[[ "$(sh_ id -u)" == 0 ]] || dadb root >/dev/null 2>&1 || true
dadb wait-for-device
[[ "$(sh_ id -u)" == 0 ]] || die "need root adb (scripts/root-phone.sh $NICK)"

# ---- install ---------------------------------------------------------------
if ! sh_ pm path "$PKG" >/dev/null 2>&1; then
    APK=$(ls -1 "$APKS"/"$PKG"_*.apk 2>/dev/null | sort -V | tail -1 || true)
    if [[ -z "$APK" ]]; then
        APK="$APKS/${PKG}_${FDROID_VC}.apk"
        say "fetching $(basename "$APK") from F-Droid"
        mkdir -p "$APKS"
        curl -fsSL -o "$APK.part" "https://f-droid.org/repo/$(basename "$APK")" && mv "$APK.part" "$APK"
    fi
    say "installing $(basename "$APK")"
    dadb install -r "$APK" >/dev/null
fi

# ---- configure -------------------------------------------------------------
say "defaults.json, permissions, accessibility"
FILES=/sdcard/Android/data/$PKG/files
JSON="{\"port\":$VNC_PORT,\"password\":\"$VNC_PASSWORD\",\"accessKey\":\"$VNC_ACCESS_KEY\",\"startOnBoot\":true,\"startOnBootDelay\":10,\"viewOnly\":false,\"showPointers\":true}"
# Owned by the app or it can't read it, and then ignores ACTION_START: the key
# it compares against is one it made up itself.
APP_UID=$(sh_ stat -c %u "/data/data/$PKG")
sh_ "mkdir -p $FILES && echo '$JSON' > $FILES/defaults.json && chown -R $APP_UID:ext_data_rw /sdcard/Android/data/$PKG"

sh_ pm grant "$PKG" android.permission.POST_NOTIFICATIONS
sh_ appops set "$PKG" PROJECT_MEDIA allow
sh_ appops set "$PKG" SYSTEM_ALERT_WINDOW allow
sh_ dumpsys deviceidle whitelist "+$PKG" >/dev/null

SVC=$PKG/.InputService
CUR=$(sh_ settings get secure enabled_accessibility_services)
case ":$CUR:" in
    *":$SVC:"*) ;;
    ":null:"|"::") sh_ settings put secure enabled_accessibility_services "$SVC" ;;
    *)             sh_ settings put secure enabled_accessibility_services "$CUR:$SVC" ;;
esac
sh_ settings put secure accessibility_enabled 1

# ---- start -----------------------------------------------------------------
say "starting the server"
sh_ am start-foreground-service -n "$PKG/.MainService" -a "$PKG.ACTION_START" \
    --es "$PKG.EXTRA_ACCESS_KEY" "$VNC_ACCESS_KEY" \
    --ei "$PKG.EXTRA_PORT" "$VNC_PORT" \
    --es "$PKG.EXTRA_PASSWORD" "$VNC_PASSWORD" \
    --ez "$PKG.EXTRA_VIEW_ONLY" false >/dev/null
for _ in $(seq 15); do listening && break; sleep 1; done
listening || die "not listening on $VNC_PORT after 15 s (logcat | grep -i droidvnc)"

IP=$(wifi_ip || true)
say "VNC up on $NICK, port $VNC_PORT (password in $VNC_CONF)"
[[ -n "$IP" ]] && echo "   LAN:  vncviewer $IP:$VNC_PORT"
echo "   USB:  adb -s $SERIAL forward tcp:5901 tcp:$VNC_PORT && vncviewer localhost:5901"
