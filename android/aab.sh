#!/usr/bin/env bash
# Builds the Android App Bundle that Google Play takes, into dist/, signed with
# the upload key. Play re-signs what it hands out, so this key only proves an
# upload is ours. Keep it, and its passwords, out of the repo and backed up.
#
# Make one once with:
#   keytool -genkeypair -keystore ~/.android/spppd-upload.jks -alias upload \
#     -keyalg RSA -keysize 4096 -validity 10000
#
# Then:
#   UPLOAD_KEYSTORE=~/.android/spppd-upload.jks make aab
#
# It asks for the passwords, or reads UPLOAD_STOREPASS and UPLOAD_KEYPASS. Also takes
# UPLOAD_ALIAS (default upload), ANDROID_HOME, JAVA_HOME, GAME and OUTPUT as apk.sh does.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
ver=$(sed -n 's/.*VERSION = "\(.*\)".*/\1/p' "$repo/src/config.lua")
love_android="$repo/android/love-android"
output=$(realpath -m "${OUTPUT:-$repo/dist/spppd-$ver.aab}")
game=$(realpath "${GAME:-$repo/dist/spppd-$ver.love}")
keystore=${UPLOAD_KEYSTORE:-}
alias=${UPLOAD_ALIAS:-upload}

if [ -z "$keystore" ] || [ ! -f "$keystore" ]; then
  echo "No upload key: set UPLOAD_KEYSTORE to it. See the top of android/aab.sh."
  exit 1
fi

export ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export JAVA_HOME="${JAVA_HOME:-/usr/lib64/jvm/java-17-openjdk-17}"

"$repo/android/prepare.sh" "$game"
(cd "$love_android" && ./gradlew --no-daemon --console=plain bundleEmbedNoRecordRelease)
bundle=$(find "$love_android/app/build/outputs/bundle" -path '*embedNoRecordRelease/*.aab' | head -1)

mkdir -p "$(dirname "$output")"
cp "$bundle" "$output"
args=(-keystore "$keystore" -sigalg SHA256withRSA -digestalg SHA-256)
[ -n "${UPLOAD_STOREPASS:-}" ] && args+=(-storepass "$UPLOAD_STOREPASS")
[ -n "${UPLOAD_KEYPASS:-}" ] && args+=(-keypass "$UPLOAD_KEYPASS")
"$JAVA_HOME/bin/jarsigner" "${args[@]}" "$output" "$alias"
"$JAVA_HOME/bin/jarsigner" -verify "$output" | tail -1
ls -la "$output"
