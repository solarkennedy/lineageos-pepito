#!/system/bin/sh
# voipstream.sh — run VoipStream with an orderly release on SIGTERM/SIGINT/HUP.
# ART kills app_process on SIGTERM without running any Java code, so this wrapper
# traps the signal and creates a stop file the tool polls every 200 ms.
#   sh /data/local/tmp/voipstream.sh <record|play|both|mode-comm> [seconds] [--tone]
D=${VOIPSTREAM_DIR:-/data/local/tmp}
S=$D/.voipstream.$$.stop
rm -f "$S"
VOIPSTREAM_STOP=$S CLASSPATH=$D/voipstream.jar app_process / VoipStream "$@" &
P=$!
trap 'touch "$S"' TERM INT HUP
while kill -0 $P 2>/dev/null; do wait $P; RC=$?; done
rm -f "$S"
exit $RC
