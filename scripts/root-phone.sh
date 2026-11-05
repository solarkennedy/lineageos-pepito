#!/usr/bin/env bash
# Turn on rooted debugging on a bench unit from the host, with nobody at the phone:
# a root adbd now, and Settings > Developer options > Rooted debugging on, so later
# `adb root`s work.
#
# Usage:
#   ./root-phone.sh new2                 # root adbd + Rooted debugging on
#   ./root-phone.sh new2 --root-on-boot  # ...and keep adbd rooted across reboots
#   ./root-phone.sh new2 --status        # show the three switches, change nothing
#
# `adb root` refuses while Rooted debugging is off (it always is after a wipe).
# adbd itself only reads service.adb.root (a prop shell may set) when it starts,
# so this sets it and restarts adbd, then turns the Settings toggle on
# (/data/adbroot/enabled, read by the adb_root service) so Settings shows the
# truth. --root-on-boot sets persist.vendor.xiaomi.adbroot=1, which
# init.xiaomi.device.rc turns into service.adb.root=1 at every boot.
#
# The unit is resolved through ~/.config/pepito/units.conf ($PEPITO_UNITS) like
# flash-staging.sh, and every adb call is pinned to its USB serial.
# setup-phone.sh runs this for its root step.

set -euo pipefail

UNIT=""
MODE=root
ROOT_ON_BOOT=0

die() { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARNING: $*" >&2; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --root-on-boot) ROOT_ON_BOOT=1 ;;
        --status)       MODE=status ;;
        -h|--help)      sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)             die "unknown option $1 (try --help)" ;;
        *)              UNIT=$1 ;;
    esac
    shift
done
[[ -n "$UNIT" ]] || die "which unit? (nick, serial or IMEI; there is deliberately no default)"

# Resolve nick/serial/IMEI → nick + serial via the roster (same rules as flash-staging.sh).
UNITS_CONF=${PEPITO_UNITS:-$HOME/.config/pepito/units.conf}
ROW=""
[[ -f "$UNITS_CONF" ]] && ROW=$(awk -v w="$UNIT" '!/^#/ && NF>=6 && !/^DAILY=/ && ($1==w || $2==w || $3==w){print; exit}' "$UNITS_CONF")
if [[ -n "$ROW" ]]; then
    read -r NICK SERIAL _ TS_IP LAN_IP _ <<<"$ROW"
    [[ "$SERIAL" != "-" ]] || die "$NICK has no serial in $UNITS_CONF"
else
    [[ "$UNIT" =~ ^[0-9A-Za-z]{6,}$ ]] || die "'$UNIT' is not in $UNITS_CONF and doesn't look like a serial"
    NICK=$UNIT SERIAL=$UNIT TS_IP=- LAN_IP=-
fi

dadb() { adb -s "$SERIAL" "$@" </dev/null; }
sh_() { dadb shell "$@" | tr -d '\r'; }
is_root() { [[ "$(sh_ id -u 2>/dev/null)" == 0 ]]; }

[[ "$(sh_ getprop ro.serialno)" == "$SERIAL" ]] || die "adb -s $SERIAL isn't reachable (or answered as another phone)"

get_root() {
    is_root && return 0
    local out
    out=$(dadb root 2>&1 | tr -d '\r' || true)
    if grep -q "disabled by system setting" <<<"$out"; then
        # Rooted debugging is off. adbd reads service.adb.root at startup; shell
        # may set it, and `adb usb`/`adb tcpip` make adbd exit so init restarts
        # it. tcpip on units reached over the network: `adb usb` would set
        # service.adb.tcp.port=0 and close TCP until the next reboot.
        echo "   Rooted debugging is off; restarting adbd with service.adb.root=1"
        # Even a refused root: restarts adbd (exit_on_close), so let it come back first.
        sleep 3
        timeout 60 adb -s "$SERIAL" wait-for-device </dev/null || true
        sh_ setprop service.adb.root 1
        if [[ "$TS_IP" != "-" || "$LAN_IP" != "-" ]]; then dadb tcpip 5555 >/dev/null; else dadb usb >/dev/null; fi
    elif [[ -n "$out" ]]; then
        echo "   $out"
    fi
    sleep 3
    timeout 60 adb -s "$SERIAL" wait-for-device </dev/null || true
    local i
    for i in $(seq 1 20); do is_root && return 0; sleep 1; done
    die "could not get a root adbd on $NICK (adb root said: ${out:-nothing})"
}

# Settings > Developer options > Rooted debugging, as adb_root keeps it.
root_toggle_on() {
    [[ "$(sh_ cat /data/adbroot/enabled 2>/dev/null)" == 1 ]] && return 0
    sh_ 'mkdir -p /data/adbroot && echo 1 > /data/adbroot/enabled'
    # adb_root reads the file only when it starts.
    sh_ setprop ctl.restart adb_root 2>/dev/null || warn "couldn't restart adb_root; the toggle shows on after a reboot"
}

if [[ "$MODE" == status ]]; then
    printf '%-18s %s\n' \
        "adbd root" "$(is_root && echo yes || echo no)" \
        "rooted debugging" "$(is_root && sh_ cat /data/adbroot/enabled 2>/dev/null || echo '? (needs root to read)')" \
        "root on boot" "$(sh_ getprop persist.vendor.xiaomi.adbroot)"
    exit 0
fi

echo "Target: $NICK ($SERIAL)"
get_root
root_toggle_on
echo "   adbd root, Rooted debugging on"
if [[ "$ROOT_ON_BOOT" -eq 1 ]]; then sh_ setprop persist.vendor.xiaomi.adbroot 1; echo "   root on boot"; fi
