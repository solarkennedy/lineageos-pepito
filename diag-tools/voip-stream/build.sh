#!/bin/bash
# build.sh — compile VoipStream into an app_process-runnable dex jar.
# Needs javac (17+), d8 and an SDK android.jar (API 34+ for AudioRecord/AudioTrack
# Builder.setContext). Defaults to ~/Android/Sdk; override with ANDROID_JAR / D8.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
ANDROID_JAR="${ANDROID_JAR:-$HOME/Android/Sdk/platforms/android-36/android.jar}"
D8="${D8:-d8}"
OUT="$DIR/out"
rm -rf "$OUT"; mkdir -p "$OUT/classes"
javac --release 11 -Xlint:-options -cp "$ANDROID_JAR" -d "$OUT/classes" "$DIR/src/VoipStream.java"
"$D8" --min-api 34 --lib "$ANDROID_JAR" --output "$OUT/voipstream.jar" $(find "$OUT/classes" -name '*.class')
echo "built: $OUT/voipstream.jar"
