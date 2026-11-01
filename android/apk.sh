#!/usr/bin/env bash
# Builds the Android test APK into dist/. The first run clones and compiles LÖVE
# for Android into dist/love-android, which takes a while and about 1 GB. After
# that, only the game inside the APK is swapped, which takes seconds.
#
# Needs the Android SDK and NDK, and JDK 17. Override these if yours live elsewhere:
#   ANDROID_HOME, JAVA_HOME, BUILD_TOOLS, GAME (a .love to pack instead of the game)
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
ver=$(sed -n 's/^ver := //p' "$repo/Makefile")
love_android="$repo/dist/love-android"
work="$repo/dist/apk-work"
output="$repo/dist/spppd-$ver-android.apk"
keystore="$HOME/.android/spppd-test.keystore"
game="${GAME:-$repo/dist/spppd-$ver.love}"

export ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export JAVA_HOME="${JAVA_HOME:-/usr/lib64/jvm/java-17-openjdk-17}"
tools="$ANDROID_HOME/build-tools/${BUILD_TOOLS:-36.0.0}"

find_unsigned() {
  find "$love_android/app/build/outputs/apk" -name '*release*.apk' 2>/dev/null | head -1
}

if [ -z "$(find_unsigned)" ]; then
  if [ ! -d "$love_android" ]; then
    git clone --depth 1 --branch 11.5a --recurse-submodules --shallow-submodules \
      https://github.com/love2d/love-android "$love_android"
  fi
  sed -i -e 's/^app\.name_byte_array=.*/app.name=SPPPD/' \
    -e 's/^app\.application_id=.*/app.application_id=xyz.hblabs.spppd/' \
    -e 's/^app\.version_code=.*/app.version_code=1/' \
    -e "s/^app\.version_name=.*/app.version_name=$ver/" "$love_android/gradle.properties"
  mkdir -p "$love_android/app/src/embed/assets"
  cp "$game" "$love_android/app/src/embed/assets/game.love"
  (cd "$love_android" && ./gradlew --no-daemon --console=plain assembleEmbedNoRecordRelease)
fi

# A test key, kept so later builds install over this one.
if [ ! -f "$keystore" ]; then
  keytool -genkeypair -keystore "$keystore" -alias spppd -keyalg RSA -keysize 2048 \
    -validity 10000 -storepass android -keypass android -dname "CN=SPPPD Test"
fi

rm -rf "$work"
mkdir -p "$work/assets"
cp "$(find_unsigned)" "$work/base.apk"
cp "$game" "$work/assets/game.love"
(cd "$work" && zip -q -0 base.apk assets/game.love)
"$tools/zipalign" -p -f 4 "$work/base.apk" "$work/aligned.apk"
"$tools/apksigner" sign --ks "$keystore" --ks-pass pass:android --ks-key-alias spppd \
  --out "$output" "$work/aligned.apk"
"$tools/apksigner" verify "$output"
rm -rf "$work"
ls -la "$output"
