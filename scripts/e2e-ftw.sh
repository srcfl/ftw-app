#!/bin/sh
# Drive the shipped client against a live FTW box.
# Usage: scripts/e2e-ftw.sh [box-host:port]
set -eu
BOX="${1:-${FTW_LIVE_BOX:-127.0.0.1:18080}}"
RELAY="${FTW_LIVE_RELAY:-wss://relay.ftw.energy}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export JAVA_HOME="${JAVA_HOME:-$(brew --prefix openjdk@21)/libexec/openjdk.jdk/Contents/Home}"
export PATH="$JAVA_HOME/bin:$PATH"
export FTW_LIVE_BOX="$BOX"
export FTW_LIVE_RELAY="$RELAY"
cd "$ROOT"
exec ./gradlew :shared:jvmTest --tests energy.ftw.client.FtwLiveBoxTest --info
