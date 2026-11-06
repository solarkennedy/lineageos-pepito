#!/usr/bin/env bash
# Bring a freshly wiped bench unit back to test-ready with nobody at the phone:
# adb authorized, rooted debugging on, setup wizard finished, on Wi-Fi, Wi-Fi
# calling on and Wi-Fi preferred (what the Wi-Fi call tests expect).
#
# Usage:
#   ./setup-phone.sh dut1                  # set up a unit that has just booted from a wipe
#   ./setup-phone.sh dut1 --wipe           # factory-reset it first (Test Harness Mode), then set up
#   ./setup-phone.sh dut1 --google         # ...then open Google sign-in and wait for it
#   ./setup-phone.sh dut1 --save-wifi      # write wifi.conf from the network the unit is on
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
# Any other wipe (recovery, flash-staging.sh --bcb-wipe) takes the phone's list
# of trusted adb hosts with it, and nothing host-side gets that back: the script
# waits for someone to tap "Allow USB debugging" on the phone.
#
# WI-FI comes from ~/.config/pepito/wifi.conf (never committed), shell syntax:
#   WIFI_SSID='🏞 Guest'
#   WIFI_PSK='...'
#   WIFI_SECURITY=wpa2        # optional: open | owe | wpa2 | wpa3 (cmd wifi connect-network)
#
# Rooting: `adb root` refuses while Settings > Developer options > Rooted
# debugging is off, which it is after a wipe. root-phone.sh (also usable on
# its own) gets a root adbd anyway and turns the Settings toggle on.
#
# After a Test Harness Mode wipe (flash-staging.sh --wipe) it also undoes that
# mode's side effects: persist.sys.test_harness, lock screen disabled, stay-awake,
# OTA auto-update off, account auto-sync off.
#
# The setup wizard is finished the way its own finishSetupWizard() does it: the
# provisioned flags, then its HOME activity disabled. (Its FinishActivity, which
# upstream's exit_wizard.sh starts, only finishes on a tap of its button.)
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
# Default HOME: the build ships Launcher3 and PepitoLauncher2, so a fresh /data
# shows the "choose a home app" picker. test_system expects Launcher3.
HOME_ACTIVITY=${PEPITO_HOME:-com.android.launcher3/.uioverrides.QuickstepLauncher}
WIFI_CONF=${PEPITO_WIFI_CONF:-$HOME/.config/pepito/wifi.conf}

die() { echo "ERROR: $*" >&2; exit 1; }
say() { echo "== $*"; }
warn() { echo "WARNING: $*" >&2; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --wipe)         WIPE=1 ;;
        --save-wifi)    MODE=save_wifi ;;
        --status)       MODE=status ;;
        --no-wifi)      WIFI=0 ;;
        --no-pattern)   PATTERN_ON=0 ;;
        --no-dexopt)    DEXOPT=0 ;;
        --root-on-boot) ROOT_ON_BOOT=1 ;;
        --google)       GOOGLE=1 ;;
        --auth-wait)    [[ -n "${2:-}" ]] || die "$1 needs a value"; AUTH_WAIT=$2; shift ;;
        -h|--help)      sed -n '2,49p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
                    echo "   Tap \"Allow\" on the phone (tick \"Always allow\"). Wiping with --wipe"
                    echo "   (Test Harness Mode) next time keeps the authorization."
                    notify "Setup: tap Allow on $NICK" "USB debugging prompt is up"
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

# Root adbd now and Rooted debugging on: scripts/root-phone.sh does both.
get_root() {
    is_root && [[ "$(sh_ cat /data/adbroot/enabled 2>/dev/null)" == 1 ]] && return 0
    "$(dirname "$(readlink -f "$0")")/root-phone.sh" "$SERIAL" | grep -v '^Target:' || die "root-phone.sh failed on $NICK"
}

# ---- Wi-Fi config ----------------------------------------------------------

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
        f.write("# written by setup-phone.sh --save-wifi\n")
        f.write("WIFI_SSID=%s\nWIFI_PSK=%s\nWIFI_SECURITY=%s\n"
                % (shlex.quote(ssid), shlex.quote(psk), "wpa2" if psk else "open"))
    print("   saved Wi-Fi %r to %s" % (ssid, out))
    break
else:
    print("WARNING: %r not in WifiConfigStore.xml" % ssid, file=sys.stderr)
' "$ssid" "$WIFI_CONF")
}

# ---- setup steps -----------------------------------------------------------

home() { sh_ cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME | tail -1; }

finish_wizard() {
    # Provisioned is not enough: Test Harness Mode sets both flags without running the
    # wizard, whose HOME activity then still starts (and hides the status bar) at boot.
    if [[ "$(setting secure user_setup_complete)" == 1 && "$(setting global device_provisioned)" == 1 \
            && "$(home)" != $SUW/* ]]; then
        echo "   already finished"
        set_home
        return 0
    fi
    # What finishSetupWizard() does that matters here (SetupWizardUtils.kt): the two
    # flags, then disable the wizard's HOME activity. Its FinishActivity is no use from a
    # script: it only finishes when its button is tapped. Force-stopping the wizard drops
    # the status-bar disable it holds (StatusBarManager token dies with the process).
    sh_ settings put global device_provisioned 1
    sh_ settings put secure user_setup_complete 1
    sh_ pm disable $SUW/.SetupWizardActivity >/dev/null
    sh_ am force-stop $SUW
    set_home
    sh_ input keyevent KEYCODE_WAKEUP
    sh_ input keyevent KEYCODE_HOME
    [[ "$(home)" != $SUW/* ]] || warn "HOME still resolves to the setup wizard"
    echo "   provisioned=$(setting global device_provisioned) user_setup_complete=$(setting secure user_setup_complete) home=$(home)"
}

# Pick the default launcher only when nothing is (the chooser): never override a choice.
set_home() {
    [[ "$(home)" == android/com.android.internal.app.ResolverActivity ]] || return 0
    sh_ cmd package set-home-activity "$HOME_ACTIVITY" >/dev/null \
        && echo "   default launcher: $HOME_ACTIVITY" || warn "couldn't set $HOME_ACTIVITY as HOME"
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
        if sh_ cmd wifi status | grep -qF "connected to \"$WIFI_SSID\"" \
                && ip=$(sh_ cmd wifi status | grep -o 'IP: /[0-9.]*' | head -1) && [[ -n "$ip" ]]; then
            echo "   on $WIFI_SSID: $ip"
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
    printf '%-22s %s\n' \
        build "$(sh_ getprop ro.lineage.version)" \
        "adbd root" "$(is_root && echo yes || echo no)" \
        "rooted debugging" "$(is_root && sh_ cat /data/adbroot/enabled 2>/dev/null || echo '?')" \
        "test harness" "$(sh_ getprop persist.sys.test_harness)" \
        provisioned "$(setting global device_provisioned)/$(setting secure user_setup_complete)" \
        wifi "$(sh_ cmd wifi status | grep -o 'connected to "[^"]*"' || echo 'not connected')" \
        "mobile data" "$(setting global mobile_data)" \
        "wi-fi calling" "$(sh_ content query --uri content://telephony/siminfo --projection wfc_ims_enabled:wfc_ims_mode --where "$(q 'sim_id>=0')" 2>/dev/null | sed 's/^Row: [0-9]* //' | head -1)" \
        google "$(sh_ dumpsys account | grep -o 'Account {name=[^,]*, type=com.google}' | head -1 || true)"
}

# Wi-Fi calling on, Wi-Fi preferred: the state tests/integration's Wi-Fi call
# tests are written for (test_call_hold asserts it). A fresh /data leaves the
# sub at -1/-1, i.e. the carrier default, which on T-Mobile is cellular
# preferred; that silently turned test_call_hold into a different test after a
# wipe (dut1, 2026-11-05). There is no cmd for it, so write siminfo and reboot,
# only when it changes: A17's SubscriptionManagerService caches siminfo, so a
# phone-process restart is not enough for WfcBridge to see it (dut1 2026-11-06).
wfc_setup() {
    local row id en mode
    row=$(sh_ content query --uri content://telephony/siminfo \
          --projection _id:wfc_ims_enabled:wfc_ims_mode --where "$(q 'sim_id>=0')" 2>/dev/null | head -1 || true)
    id=$(sed -n 's/.*_id=\([0-9]*\).*/\1/p' <<<"$row")
    en=$(sed -n 's/.*wfc_ims_enabled=\(-\?[0-9]*\).*/\1/p' <<<"$row")
    mode=$(sed -n 's/.*wfc_ims_mode=\(-\?[0-9]*\).*/\1/p' <<<"$row")
    if [[ -z "$id" ]]; then warn "no active SIM: Wi-Fi calling not set"; return 0; fi
    if [[ "$en" == 1 && "$mode" == 2 ]]; then echo "   already on, Wi-Fi preferred"; return 0; fi
    sh_ content update --uri content://telephony/siminfo \
        --bind wfc_ims_enabled:i:1 --bind wfc_ims_mode:i:2 --where "$(q "_id=$id")" >/dev/null \
        || { warn "couldn't set Wi-Fi calling in siminfo"; return 0; }
    echo "   sub $id: was enabled=$en mode=$mode, now on + Wi-Fi preferred; rebooting so it takes"
    sh_ reboot >/dev/null 2>&1 || true
    local i
    for i in $(seq 1 60); do [[ "$(state)" == device ]] || break; sleep 2; done
    wait_authorized; wait_boot; get_root
}

case "$MODE" in
    save_wifi) wait_authorized; wait_boot; get_root; save_wifi; exit 0 ;;
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
if [[ "$ROOT_ON_BOOT" -eq 1 ]]; then sh_ setprop persist.vendor.xiaomi.adbroot 1; echo "   root on boot"; fi
# Developer options shown; never time out this host's authorization.
sh_ settings put global development_settings_enabled 1
sh_ settings put global adb_allowed_connection_time 0
tcp_adb
undo_test_harness
say "setup wizard"
finish_wizard
if [[ "$WIFI" -eq 1 ]]; then say "Wi-Fi"; join_wifi; fi
# Lineage seeds mobile data OFF on every fresh /data (ro.com.android.mobiledata=false).
sh_ svc data enable
say "Wi-Fi calling (on, Wi-Fi preferred)"
wfc_setup
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
