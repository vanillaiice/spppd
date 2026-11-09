#!/usr/bin/env bash
# Builds the Android APK into dist/, signed with a local test key. LÖVE for Android
# is the android/love-android submodule; prepare.sh sets it up. The first build of
# a version compiles LÖVE, which takes a while; after that only the game inside the
# APK is swapped, which takes seconds.
#
# Needs the Android SDK and NDK, and JDK 17. Override these if yours live elsewhere:
#   ANDROID_HOME, JAVA_HOME, BUILD_TOOLS, GAME (a .love to pack instead of the game),
#   OUTPUT (where the APK goes)
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
ver=$(sed -n 's/.*VERSION = "\(.*\)".*/\1/p' "$repo/src/config.lua")
code=$(sed -n 's/.*VERSION_CODE = \([0-9]*\).*/\1/p' "$repo/src/config.lua")
love_android="$repo/android/love-android"
work="$repo/dist/apk-work"
output=$(realpath -m "${OUTPUT:-$repo/dist/spppd-$ver-android.apk}")
keystore="$HOME/.android/spppd-test.keystore"
game=$(realpath "${GAME:-$repo/dist/spppd-$ver.love}")

export ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export JAVA_HOME="${JAVA_HOME:-/usr/lib64/jvm/java-17-openjdk-17}"
tools="$ANDROID_HOME/build-tools/${BUILD_TOOLS:-36.0.0}"

"$repo/android/prepare.sh" "$game"

# The compiled APK carries the version, and prepare.sh sets the toolchain, so it's
# rebuilt when either changes.
outputs="$love_android/app/build/outputs/apk"
stamp="$outputs/spppd-base"
want="$code $(md5sum "$repo/android/prepare.sh" | cut -c1-12)"
unsigned=$(find "$outputs" -path '*embedNoRecord/release/*.apk' 2>/dev/null | head -1 || true)
if [ -z "$unsigned" ] || [ "$(cat "$stamp" 2>/dev/null)" != "$want" ]; then
  (cd "$love_android" && ./gradlew --no-daemon --console=plain assembleEmbedNoRecordRelease)
  echo "$want" > "$stamp"
  unsigned=$(find "$outputs" -path '*embedNoRecord/release/*.apk' | head -1)
fi

# A test key, kept so later builds install over this one.
if [ ! -f "$keystore" ]; then
  keytool -genkeypair -keystore "$keystore" -alias spppd -keyalg RSA -keysize 2048 \
    -validity 10000 -storepass android -keypass android -dname "CN=SPPPD Test"
fi

rm -rf "$work"
mkdir -p "$work/assets"
cp "$unsigned" "$work/base.apk"
cp "$game" "$work/assets/game.love"
(cd "$work" && zip -q -0 base.apk assets/game.love)
# Native libraries on 16 KB page boundaries, as Google Play asks.
"$tools/zipalign" -P 16 -f 4 "$work/base.apk" "$work/aligned.apk"
"$tools/apksigner" sign --ks "$keystore" --ks-pass pass:android --ks-key-alias spppd \
  --out "$output" "$work/aligned.apk"
"$tools/apksigner" verify "$output"
rm -rf "$work"
ls -la "$output"
