#!/usr/bin/env bash
# Bring a freshly wiped bench unit back to test-ready with nobody at the phone:
# adb authorized, rooted debugging on, setup wizard finished, on Wi-Fi.
#
# Usage:
#   ./setup-phone.sh dut1                  # set up a unit that has just booted from a wipe
#   ./setup-phone.sh dut1 --wipe           # factory-reset it first (Test Harness Mode), then set up
#   ./setup-phone.sh dut1 --google         # ...then open Google sign-in and wait for it
#   ./setup-phone.sh dut1 --enroll         # once per unit, BEFORE the wipe (see below)
#   ./setup-phone.sh dut1 --unenroll       # forget the enrolled keys (do this before a sale)
#   ./setup-phone.sh dut1 --status         # what is and isn't set up, change nothing
#
# Options:
#   --no-wifi        don't join Wi-Fi
#   --no-pattern     don't put the roster's lock pattern back
#   --no-dexopt      skip `pm bg-dexopt-job` (gapps: ~2 min, undoes the post-flash JIT slowness)
#   --root-on-boot   also set persist.vendor.xiaomi.adbroot=1 (adbd rooted from boot)
#   --google         after setup, open "Add account > Google" and wait for the sign-in
#   --auth-wait <s>  how long to wait for adb authorization (default 600)
#
# --wipe runs `cmd testharness enable`: Android's own factory reset that keeps
# the adb keys (parked in the FRP block, our `config` partition, restored on the
# first boot) and marks the unit provisioned, so it comes back authorized with
# nobody at it. It refuses a secure lockscreen, so the roster pattern is cleared
# first (and put back at the end). flash-staging.sh --wipe ends with this.
#
# ADB AUTHORIZATION after any other wipe (recovery, flash-staging.sh --bcb-wipe). A wipe takes the phone's list of trusted adb hosts with it,
# and nothing host-side can get that back: the "Allow USB debugging" dialog
# needs a tap. Builds with device/xiaomi/Mi8937 e176ec0a (init.pepito-adbkeys.rc)
# restore the list from /mnt/vendor/persist/pepito/adb_keys on the first boot
# after a wipe; /persist survives it. `--enroll` writes that file: this host's
# ~/.android/adbkey.pub plus any keys in ~/.config/pepito/adb_keys (other
# machines that drive the bench), and needs an authorized, rooted adb, so run
# it once while the unit is still set up. A unit that isn't enrolled (or runs an
# older build) still works: the script waits for someone to tap "Allow".
#
# WI-FI comes from ~/.config/pepito/wifi.conf (never committed), shell syntax:
#   WIFI_SSID='🏞 Guest'
#   WIFI_PSK='...'
#   WIFI_SECURITY=wpa2        # optional: open | owe | wpa2 | wpa3 (cmd wifi connect-network)
#
# Rooting: `adb root` refuses while Settings > Developer options > Rooted
# debugging is off, which it is after a wipe. adbd itself only reads
# service.adb.root (a prop shell may set) when it starts, so the script sets it
# and restarts adbd, then turns the Settings toggle on (/data/adbroot/enabled)
# so later `adb root`s work and Settings shows the truth.
#
# After a Test Harness Mode wipe (flash-staging.sh --wipe) it also undoes that
# mode's side effects: persist.sys.test_harness, lock screen disabled, stay-awake,
# OTA auto-update off, account auto-sync off.
#
# The setup wizard is finished through its own FinishActivity (as upstream's
# packages/apps/SetupWizard/exit_wizard.sh does), which marks the device
# provisioned and disables the wizard's HOME activity.
#
# The unit is resolved through ~/.config/pepito/units.conf ($PEPITO_UNITS) like
# flash-staging.sh, and every adb call is pinned to its USB serial. Runs straight
# after `flash-staging.sh <unit> --wipe`, which chains into it.

set -euo pipefail

UNIT=""
MODE=setup
WIFI=1
PATTERN_ON=1
DEXOPT=1
ROOT_ON_BOOT=0
GOOGLE=0
WIPE=0
AUTH_WAIT=600
SUW=org.lineageos.setupwizard
PERSIST_KEYS=/mnt/vendor/persist/pepito/adb_keys
WIFI_CONF=${PEPITO_WIFI_CONF:-$HOME/.config/pepito/wifi.conf}
EXTRA_KEYS=$HOME/.config/pepito/adb_keys

die() { echo "ERROR: $*" >&2; exit 1; }
say() { echo "== $*"; }
warn() { echo "WARNING: $*" >&2; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --wipe)         WIPE=1 ;;
        --enroll)       MODE=enroll ;;
        --unenroll)     MODE=unenroll ;;
        --status)       MODE=status ;;
        --no-wifi)      WIFI=0 ;;
        --no-pattern)   PATTERN_ON=0 ;;
        --no-dexopt)    DEXOPT=0 ;;
        --root-on-boot) ROOT_ON_BOOT=1 ;;
        --google)       GOOGLE=1 ;;
        --auth-wait)    [[ -n "${2:-}" ]] || die "$1 needs a value"; AUTH_WAIT=$2; shift ;;
        -h|--help)      sed -n '2,58p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
PATTERN=""
[[ -f "$UNITS_CONF" ]] && PATTERN=$(awk -v n="$NICK" '$1=="PATTERN" && $2==n {print $3; exit}' "$UNITS_CONF")
echo "Target: $NICK ($SERIAL)"

dadb() { adb -s "$SERIAL" "$@" </dev/null; }
sh_() { dadb shell "$@" | tr -d '\r'; }
# Single-quote a string for the phone's shell (adb shell re-joins its args into one line).
q() { printf "'%s'" "${1//\'/\'\\\'\'}"; }
state() { adb -s "$SERIAL" get-state 2>&1 | tr -d '\r' || true; }
is_root() { [[ "$(sh_ id -u 2>/dev/null)" == 0 ]]; }
setting() { sh_ settings get "$1" "$2" 2>/dev/null; }

notify() { /home/kyle/.bin/ntfy-main "$1" "$2" "${3:-default}" >/dev/null 2>&1 || true; }

# ---- adb: present, authorized, booted, right phone -------------------------

# Seconds to sit on "unauthorized" before asking for a tap: after a Test Harness
# wipe the keys only come back late in the first boot (boot phase completed).
AUTH_GRACE=0

wait_authorized() {
    local t0=$SECONDS st told=0 unauth_since=""
    while :; do
        st=$(state)
        case "$st" in
            device) break ;;
            *unauthorized*)
                unauth_since=${unauth_since:-$SECONDS}
                if [[ $told -eq 0 ]] && (( SECONDS - unauth_since >= AUTH_GRACE )); then
                    say "$NICK is on adb but this host isn't authorized."
                    echo "   Tap \"Allow\" on the phone (tick \"Always allow\"). Next time, enroll the unit"
                    echo "   while it's still set up so wipes don't need this:  $0 $NICK --enroll"
                    notify "Setup: tap Allow on $NICK" "USB debugging prompt is up (unit not enrolled)"
                    told=1
                fi ;;
        esac
        (( SECONDS - t0 < AUTH_WAIT )) || die "$NICK not authorized on adb after ${AUTH_WAIT}s (state: ${st:-absent})"
        sleep 3
    done
    [[ "$(sh_ getprop ro.serialno)" == "$SERIAL" ]] || die "adb -s $SERIAL answered as another phone?!"
}

wait_boot() {
    local t0=$SECONDS
    until [[ "$(sh_ getprop sys.boot_completed 2>/dev/null)" == 1 ]]; do
        (( SECONDS - t0 < 300 )) || die "$NICK never reported boot_completed"
        sleep 2
    done
}

# ---- root ------------------------------------------------------------------

get_root() {
    is_root && return 0
    local out
    out=$(dadb root 2>&1 | tr -d '\r' || true)
    if grep -q "disabled by system setting" <<<"$out"; then
        # Rooted debugging is off (it always is after a wipe). adbd reads
        # service.adb.root at startup; shell may set it, and `adb usb`/`adb tcpip`
        # make adbd exit so init restarts it. tcpip on units reached over the
        # network: `adb usb` would set service.adb.tcp.port=0 and close TCP until
        # the next reboot.
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

# ---- enrollment ------------------------------------------------------------

host_keys() {
    [[ -f $HOME/.android/adbkey.pub ]] || die "no $HOME/.android/adbkey.pub (run any adb command once)"
    {
        cat "$HOME/.android/adbkey.pub"; echo
        if [[ -f "$EXTRA_KEYS" ]]; then grep -v '^\s*#' "$EXTRA_KEYS" || true; fi
    } | { grep -v '^\s*$' || true; } | sort -u
}

enroll() {
    wait_authorized; wait_boot; get_root
    local tmp; tmp=$(mktemp)
    host_keys > "$tmp"
    # Keep keys enrolled from other hosts: merge, don't replace.
    sh_ "cat $PERSIST_KEYS 2>/dev/null" | grep -v '^\s*$' >> "$tmp" || true
    sort -u -o "$tmp" "$tmp"
    dadb push "$tmp" /data/local/tmp/adb_keys.enroll >/dev/null
    rm -f "$tmp"
    sh_ "mkdir -p ${PERSIST_KEYS%/*} && chmod 0755 ${PERSIST_KEYS%/*} \
        && cat /data/local/tmp/adb_keys.enroll > $PERSIST_KEYS && chmod 0644 $PERSIST_KEYS \
        && rm /data/local/tmp/adb_keys.enroll && sync"
    say "enrolled $NICK: $(sh_ "wc -l < $PERSIST_KEYS") key(s) in $PERSIST_KEYS"
    sh_ "ls -Z $PERSIST_KEYS"
    [[ -f "$WIFI_CONF" ]] || save_wifi
    if [[ -z "$(sh_ 'ls /system_ext/etc/init/init.pepito-adbkeys.rc 2>/dev/null')" ]]; then
        warn "this build has no init.pepito-adbkeys.rc: the keys are stored, but only a build with it restores them after a wipe"
    fi
}

# Write $WIFI_CONF from the network the (rooted) phone is on now.
save_wifi() {
    local ssid
    ssid=$(sh_ cmd wifi status | sed -n 's/^Wifi is connected to "\(.*\)"$/\1/p')
    [[ -n "$ssid" ]] || { warn "$NICK isn't on Wi-Fi: no $WIFI_CONF written"; return 0; }
    sh_ cat /data/misc/apexdata/com.android.wifi/WifiConfigStore.xml | (umask 077; python3 -c '
import html, re, shlex, sys
ssid, out = sys.argv[1], sys.argv[2]
for blk in re.findall(r"<WifiConfiguration>(.*?)</WifiConfiguration>", sys.stdin.read(), re.S):
    m = re.search(r"name=\"SSID\">(.*?)<", blk)
    if not m or html.unescape(m.group(1)) != "\"%s\"" % ssid:
        continue
    k = re.search(r"name=\"PreSharedKey\">(.*?)<", blk)
    psk = html.unescape(k.group(1)).strip("\"") if k else ""
    with open(out, "w") as f:
        f.write("# written by setup-phone.sh --enroll\n")
        f.write("WIFI_SSID=%s\nWIFI_PSK=%s\nWIFI_SECURITY=%s\n"
                % (shlex.quote(ssid), shlex.quote(psk), "wpa2" if psk else "open"))
    print("   saved Wi-Fi %r to %s" % (ssid, out))
    break
else:
    print("WARNING: %r not in WifiConfigStore.xml" % ssid, file=sys.stderr)
' "$ssid" "$WIFI_CONF")
}

unenroll() {
    wait_authorized; wait_boot; get_root
    sh_ "rm -f $PERSIST_KEYS; rmdir ${PERSIST_KEYS%/*} 2>/dev/null; sync"
    say "unenrolled $NICK (a wipe will need a tap on \"Allow\" again)"
}

# ---- setup steps -----------------------------------------------------------

home() { sh_ cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME | tail -1; }

finish_wizard() {
    # Provisioned is not enough: Test Harness Mode sets both flags without running the
    # wizard, whose HOME activity then still starts (and hides the status bar) at boot.
    if [[ "$(setting secure user_setup_complete)" == 1 && "$(setting global device_provisioned)" == 1 \
            && "$(home)" != $SUW/* ]]; then
        echo "   already finished"
        return 0
    fi
    sh_ input keyevent KEYCODE_WAKEUP
    sh_ pm enable $SUW/.FinishActivity >/dev/null || true
    sh_ am start -n $SUW/.FinishActivity >/dev/null || true
    local i
    for i in $(seq 1 30); do
        [[ "$(setting secure user_setup_complete)" == 1 ]] && break
        sleep 1
    done
    if [[ "$(setting secure user_setup_complete)" != 1 ]]; then
        warn "FinishActivity didn't complete the wizard; marking it done by hand"
        sh_ settings put global device_provisioned 1
        sh_ settings put secure user_setup_complete 1
        sh_ pm disable $SUW/.SetupWizardActivity >/dev/null || true
    fi
    sleep 2
    sh_ input keyevent KEYCODE_HOME
    echo "   provisioned=$(setting global device_provisioned) user_setup_complete=$(setting secure user_setup_complete) home=$(home)"
}

join_wifi() {
    [[ -f "$WIFI_CONF" ]] || { warn "no $WIFI_CONF (WIFI_SSID=..., WIFI_PSK=...): not joining Wi-Fi"; return 0; }
    local WIFI_SSID="" WIFI_PSK="" WIFI_SECURITY=wpa2
    # shellcheck source=/dev/null
    . "$WIFI_CONF"
    [[ -n "$WIFI_SSID" ]] || { warn "$WIFI_CONF sets no WIFI_SSID"; return 0; }
    if sh_ cmd wifi status | grep -qF "connected to \"$WIFI_SSID\""; then
        echo "   already on $WIFI_SSID"
        return 0
    fi
    sh_ svc wifi enable
    sleep 2
    if [[ "$WIFI_SECURITY" == open || "$WIFI_SECURITY" == owe ]]; then
        sh_ "cmd wifi connect-network $(q "$WIFI_SSID") $WIFI_SECURITY" >/dev/null
    else
        sh_ "cmd wifi connect-network $(q "$WIFI_SSID") $WIFI_SECURITY $(q "$WIFI_PSK")" >/dev/null
    fi
    local i
    for i in $(seq 1 60); do
        if sh_ cmd wifi status | grep -qF "connected to \"$WIFI_SSID\""; then
            echo "   on $WIFI_SSID: $(sh_ cmd wifi status | grep -o 'IP: /[0-9.]*' | head -1)"
            return 0
        fi
        sleep 1
    done
    warn "not on $WIFI_SSID after 60 s"
}

set_pattern() {
    # set-pattern refuses once a credential exists; verify tells "already ours" from "someone else's".
    if sh_ locksettings set-pattern "$PATTERN" >/dev/null 2>&1; then
        echo "   pattern set (roster PATTERN $NICK)"
    elif sh_ locksettings verify --old "$PATTERN" >/dev/null 2>&1; then
        echo "   pattern already set"
    else
        warn "$NICK has a lock credential that isn't the roster pattern; left alone"
    fi
}

# Master sync, through IContentService: no shell command exposes it. Transaction
# numbers move between releases, so only on the SDK they were read from (37: 22 =
# setMasterSyncAutomaticallyAsUser(bool, user), 23 = getMasterSyncAutomatically),
# and only when the getter answers like a boolean before and after.
master_sync() {   # prints 0/1, or nothing when unsure
    [[ "$(sh_ getprop ro.build.version.sdk)" == 37 ]] || return 0
    sh_ service call content 23 | sed -n "s/^Result: Parcel(\s*00000000 0000000\([01]\) .*/\1/p"
}

# Test Harness Mode (flash-staging.sh --wipe) leaves the unit unlike a normal one:
# undo what it set (TestHarnessModeService.configureSettings/configureUser) except
# the adb-friendly bits (no key TTL, developer options) and location on.
undo_test_harness() {
    [[ "$(sh_ getprop persist.sys.test_harness)" == 1 ]] || return 0
    say "undoing Test Harness Mode settings"
    sh_ setprop persist.sys.test_harness 0      # apps check isRunningInUserTestHarness()
    sh_ locksettings set-disabled false >/dev/null
    sh_ settings put global stay_on_while_plugged_in 0
    sh_ settings put global ota_disable_automatic_update 0
    sh_ settings delete global package_verifier_include_adb >/dev/null
    local before; before=$(master_sync)
    if [[ "$before" == 0 ]]; then
        sh_ service call content 22 i32 1 i32 0 >/dev/null
        [[ "$(master_sync)" == 1 ]] && echo "   account auto-sync back on" \
            || warn "couldn't turn account auto-sync back on (Settings > Passwords & accounts)"
    elif [[ -z "$before" ]]; then
        warn "account auto-sync is off (Test Harness Mode); turn it on in Settings > Passwords & accounts"
    fi
}

tcp_adb() {
    # The roster gives this unit a network address, so its <nick>-adb wrapper
    # reaches it over TCP: keep adbd listening on 5555 across reboots.
    [[ "$TS_IP" == "-" && "$LAN_IP" == "-" ]] && return 0
    sh_ setprop persist.adb.tcp.port 5555
    echo "   persist.adb.tcp.port=5555 (roster: tailscale $TS_IP, lan $LAN_IP)"
}

google_signin() {
    if sh_ dumpsys account | grep -q 'Account {name=[^,]*, type=com.google}'; then
        echo "   already signed in: $(sh_ dumpsys account | grep -o 'Account {name=[^,]*, type=com.google}' | head -1)"
        return 0
    fi
    sh_ pm path com.google.android.gms >/dev/null 2>&1 || { warn "no GMS (vanilla build): skipping Google sign-in"; return 0; }
    if [[ -n "$PATTERN" ]] && command -v pepito-unlock >/dev/null; then
        pepito-unlock "adb -s $SERIAL" "$PATTERN" >/dev/null || warn "couldn't unlock $NICK; unlock it by hand"
    fi
    sh_ svc power stayon true
    sh_ am start -a android.settings.ADD_ACCOUNT_SETTINGS --esa account_types com.google >/dev/null
    say "Google sign-in is open on $NICK: finish it on the phone (waiting up to 15 min)"
    notify "Setup: sign in to Google on $NICK" "the Add account screen is open"
    local t0=$SECONDS
    until sh_ dumpsys account | grep -q 'Account {name=[^,]*, type=com.google}'; do
        (( SECONDS - t0 < 900 )) || { warn "no Google account after 15 min"; break; }
        sleep 5
    done
    sh_ settings put global stay_on_while_plugged_in 0
    sh_ dumpsys account | grep -o 'Account {name=[^,]*, type=com.google}' | head -1 || true
}

gsf_id() {
    sh_ "sqlite3 /data/data/com.google.android.gms/databases/gservices.db \
        'select value from main where name=\"android_id\";' 2>/dev/null" || true
}

status() {
    wait_authorized
    local enrolled=no
    if is_root; then
        sh_ "test -s $PERSIST_KEYS" && enrolled="yes ($(sh_ "wc -l < $PERSIST_KEYS") keys)"
    else
        enrolled="unknown (adbd not root)"
    fi
    printf '%-22s %s\n' \
        build "$(sh_ getprop ro.lineage.version)" \
        "adbd root" "$(is_root && echo yes || echo no)" \
        "rooted debugging" "$(is_root && sh_ cat /data/adbroot/enabled 2>/dev/null || echo '?')" \
        "adbkeys hook" "$(sh_ 'ls /system_ext/etc/init/init.pepito-adbkeys.rc 2>/dev/null' | grep -q . && echo present || echo 'absent (older build)')" \
        "seeded this wipe" "$(sh_ getprop persist.vendor.xiaomi.adbkeys_seeded)" \
        enrolled "$enrolled" \
        provisioned "$(setting global device_provisioned)/$(setting secure user_setup_complete)" \
        wifi "$(sh_ cmd wifi status | grep -o 'connected to "[^"]*"' || echo 'not connected')" \
        "mobile data" "$(setting global mobile_data)" \
        google "$(sh_ dumpsys account | grep -o 'Account {name=[^,]*, type=com.google}' | head -1 || true)"
}

case "$MODE" in
    enroll)   enroll; exit 0 ;;
    unenroll) unenroll; exit 0 ;;
    status)   status; exit 0 ;;
esac

# Test Harness Mode factory reset; see the header.
thm_wipe() {
    wait_authorized; wait_boot
    if ! sh_ locksettings verify >/dev/null 2>&1; then   # fails only when a credential is set
        [[ -n "$PATTERN" ]] || die "$NICK has a lock credential and no PATTERN line in $UNITS_CONF: clear it first"
        sh_ locksettings clear --old "$PATTERN" >/dev/null \
            || die "couldn't clear $NICK's lock with the roster pattern; not wiping"
        echo "   cleared the lock pattern (put back after the wipe)"
    fi
    local out
    out=$(sh_ cmd testharness enable 2>&1) || die "cmd testharness enable failed: $out"
    echo "   Test Harness Mode wipe started${out:+: $out}"
    notify "Wiping $NICK" "Test Harness Mode factory reset"
    # Wait for it to leave adb (reboot to recovery), so the pre-wipe system isn't mistaken for the fresh one.
    local i
    for i in $(seq 1 60); do [[ "$(state)" == device ]] || return 0; sleep 2; done
    die "$NICK still on adb 2 min after cmd testharness enable"
}

T0=$SECONDS
if [[ "$WIPE" -eq 1 ]]; then say "wipe (Test Harness Mode)"; thm_wipe; AUTH_GRACE=240; fi
say "waiting for $NICK on adb"
wait_authorized
say "waiting for boot to complete"
wait_boot
say "root"
get_root
root_toggle_on
if [[ "$ROOT_ON_BOOT" -eq 1 ]]; then sh_ setprop persist.vendor.xiaomi.adbroot 1; echo "   root on boot"; fi
# Developer options shown; never time out this host's authorization.
sh_ settings put global development_settings_enabled 1
sh_ settings put global adb_allowed_connection_time 0
tcp_adb
# The re-seed can't see a key that was only ever allowed through the dialog.
if sh_ "test -s $PERSIST_KEYS" && ! sh_ "cat $PERSIST_KEYS" | grep -qF "$(cut -d' ' -f1 "$HOME/.android/adbkey.pub")"; then
    warn "$NICK is enrolled but not with this host's key: re-run with --enroll"
fi
undo_test_harness
say "setup wizard"
finish_wizard
if [[ "$WIFI" -eq 1 ]]; then say "Wi-Fi"; join_wifi; fi
# Lineage seeds mobile data OFF on every fresh /data (ro.com.android.mobiledata=false).
sh_ svc data enable
if [[ "$PATTERN_ON" -eq 1 && -n "$PATTERN" ]]; then say "lock pattern"; set_pattern; fi
if [[ "$GOOGLE" -eq 1 ]]; then say "Google account"; google_signin; fi
if [[ "$DEXOPT" -eq 1 ]] && sh_ pm path com.google.android.gms >/dev/null 2>&1; then
    say "bg-dexopt (gapps)"
    # A flash leaves GMS at status=verify; once it is speed-profile the job has run.
    gms=$(sh_ dumpsys package dexopt 2>/dev/null | grep -A2 '^ *\[com.google.android.gms\]' | grep -o 'status=[a-z-]*' | head -1 || true)
    if [[ "$gms" == status=speed* ]]; then
        echo "   already done (GMS $gms)"
    else
        echo "   GMS ${gms:-status unknown}: running pm bg-dexopt-job (~2 min)"
        timeout 600 adb -s "$SERIAL" shell pm bg-dexopt-job </dev/null >/dev/null 2>&1 || warn "bg-dexopt-job didn't finish"
    fi
fi

say "done in $(( SECONDS - T0 ))s"
status
ID=$(gsf_id)
[[ -n "$ID" ]] && echo "GSF ID (Play Protect registration, new after every wipe): $ID"
notify "Setup done — $NICK" "adb root, wizard finished, Wi-Fi; $(( SECONDS - T0 ))s"
