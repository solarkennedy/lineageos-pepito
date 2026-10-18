#!/bin/bash
# run-unattended.sh <unit> [--all] [-- extra pytest args]
#
# Run the integration suite on one bench unit with nobody at the phone or the
# terminal, then push the result to ntfy (the same channel as the build
# notifications). Default: the tests the release's test plan requires
# (scripts/test_plan.py command), with the opt-in flags they need. --all: every
# test, calls, Wi-Fi walk-away and the ~15 min memory benches included. If the plan
# can't be worked out (builder asleep), it runs --all rather than nothing.
#
#   tests/integration/run-unattended.sh dut1
#   tests/integration/run-unattended.sh dut1 --all
#   nohup tests/integration/run-unattended.sh dut1 >/dev/null 2>&1 &   # fire and forget
#
# One run per unit at a time (flock). Whole run capped at $PEPITO_ITEST_MAX seconds
# (default 7200); each test also has its own budget (conftest.py). Output:
# results/unattended-<date>-<unit>.log next to the run's results/<run>/summary.json.
# PEPITO_NOTIFY=0 skips the notification. Exit status is pytest's (124 = cap hit).
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
LANDING=$(cd "$HERE/../.." && pwd)
UNIT=${1:?usage: run-unattended.sh <unit> [--all] [-- pytest args]}; shift
MODE=plan
[[ ${1:-} == --all ]] && { MODE=all; shift; }
[[ ${1:-} == -- ]] && shift

mkdir -p "$HERE/results"
exec 9>"$HERE/results/.lock-$UNIT"
flock -n 9 || { echo "run-unattended: a run on $UNIT is already going" >&2; exit 3; }

notify() {
    [[ ${PEPITO_NOTIFY:-1} == 0 ]] && return 0
    /home/kyle/.bin/ntfy-main "$1" "$2" "${3:-default}" >/dev/null 2>&1 || true
}

NOTE=""
if [[ $MODE == plan ]]; then
    if ! ARGS=$(python3 "$LANDING/scripts/test_plan.py" command 2>/dev/null) || [[ -z $ARGS ]]; then
        MODE=all; NOTE="(test plan unavailable, ran everything)"
    fi
fi
[[ $MODE == all ]] && ARGS="--allow-calls --allow-disruptive --allow-bench"

LOG="$HERE/results/unattended-$(date +%Y%m%d-%H%M%S)-$UNIT.log"
echo "run-unattended: $UNIT $MODE $NOTE -> $LOG"
cd "$HERE"
# shellcheck disable=SC2086  # ARGS is a word list from test_plan.py
timeout --kill-after=60 "${PEPITO_ITEST_MAX:-7200}" \
    python3 -m pytest --unit "$UNIT" $ARGS "$@" </dev/null >"$LOG" 2>&1
rc=$?

result=$(grep -E '^=+ .*(passed|failed|error|skipped).* in [0-9.]+s' "$LOG" | tail -1 | tr -d '=' | xargs)
source_line=$(grep -o 'source [^ ]*' "$LOG" | tail -1)
problems=$(grep -E '^(FAILED|ERROR|SKIPPED)' "$LOG" | cut -c1-160 | head -15)
case $rc in
    0)   title="✅ pepito tests $UNIT: pass"; prio=default ;;
    124) title="⏱️ pepito tests $UNIT: run cap hit"; prio=high; result="killed after ${PEPITO_ITEST_MAX:-7200} s" ;;
    *)   title="❌ pepito tests $UNIT: rc $rc"; prio=high ;;
esac
notify "$title" "${result:-no pytest summary (see log)} ${NOTE}
${source_line}
${problems}
log: $LOG" "$prio"
echo "$title — ${result}"
exit $rc
