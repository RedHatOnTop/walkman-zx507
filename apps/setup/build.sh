#!/usr/bin/env bash
# Build ZX507Setup.apk without Gradle: aapt2 (with the strings and the launcher layout), javac,
# d8, then sign with the AOSP platform test key that the GSI's framework-res uses.
#
# Needs the Android SDK's android-35 platform and build-tools 35.0.0
# (ANDROID_SDK, default ~/Android/sdk) and a JDK with jdk.compiler.
#
# Usage: apps/setup/build.sh <out.apk>

set -euo pipefail
OUT="$1"
APP="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$APP/../.." && pwd)"
SDK="${ANDROID_SDK:-$HOME/Android/sdk}"
BT="$SDK/build-tools/35.0.0"
JAR="$SDK/platforms/android-35/android.jar"
KEYS="$ROOT/tools/aosp-testkeys"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

"$BT/aapt2" compile --dir "$APP/res" -o "$WORK/res.zip"
"$BT/aapt2" link -I "$JAR" --manifest "$APP/AndroidManifest.xml" --java "$WORK/gen" \
	-o "$WORK/res.apk" "$WORK/res.zip"

mkdir "$WORK/classes"
find "$APP/src" "$WORK/gen" -name '*.java' | sort >"$WORK/sources"
java -m jdk.compiler/com.sun.tools.javac.Main -source 17 -target 17 -Xlint:-options \
	-classpath "$JAR" -d "$WORK/classes" @"$WORK/sources"
find "$WORK/classes" -name '*.class' | sort >"$WORK/class-files"
"$BT/d8" --release --min-api 33 --lib "$JAR" --output "$WORK" @"$WORK/class-files"

cp "$WORK/res.apk" "$WORK/unsigned.apk"
# zip stores the file's mtime in local time; a fixed one keeps rebuilds identical.
touch -d 2008-01-01T00:00:00Z "$WORK/classes.dex"
(cd "$WORK" && TZ=UTC zip -q -X unsigned.apk classes.dex)
"$BT/zipalign" -p -f 4 "$WORK/unsigned.apk" "$WORK/aligned.apk"
"$BT/apksigner" sign --key "$KEYS/platform.pk8" --cert "$KEYS/platform.x509.pem" \
	--out "$OUT" "$WORK/aligned.apk"
"$BT/apksigner" verify "$OUT"
echo "$OUT"
