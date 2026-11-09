#!/usr/bin/env bash
# Readies android/love-android (LÖVE's Android project, a submodule) to build
# SPPPD: the app's name, id and version, its icon, and the game inside it. Both
# apk.sh and F-Droid's build recipe run this, so the two APKs match.
#
#   android/prepare.sh [game.love]
#
# Without a .love it packs one from the repo, the same files as make zip.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
love="$repo/android/love-android"
# The NDK every build uses: apk.sh, luajit.sh and F-Droid's recipe.
NDK_VERSION=27.1.12297006
ver=$(sed -n 's/.*VERSION = "\(.*\)".*/\1/p' "$repo/src/config.lua")
code=$(sed -n 's/.*VERSION_CODE = \([0-9]*\).*/\1/p' "$repo/src/config.lua")
[ -n "$ver" ] && [ -n "$code" ] || { echo "No VERSION or VERSION_CODE in src/config.lua"; exit 1; }

if [ ! -f "$love/love/src/jni/love/Android.mk" ]; then
  git -C "$repo" submodule update --init --recursive --depth 1 android/love-android
fi

sed -i -e 's/^app\.name\(_byte_array\)\?=.*/app.name=SPPPD/' \
  -e 's/^app\.application_id=.*/app.application_id=xyz.spppd/' \
  -e "s/^app\.version_code=.*/app.version_code=$code/" \
  -e "s/^app\.version_name=.*/app.version_name=$ver/" "$love/gradle.properties"

cp -r "$repo/android/res/." "$love/app/src/main/res/"

# Google Play wants a recent target API and native code built for 16 KB memory
# pages. NDK r27 builds that, but no lower than Android 5.0 (API 21), and a newer
# Android Gradle Plugin knows API 36 and aligns the libraries in the package.
sed -i -e "s/ndkVersion '[^']*'/ndkVersion '$NDK_VERSION'/" -e 's/minSdk [0-9]*/minSdk 21/' \
  -e 's/compileSdk [0-9]*/compileSdk 36/' -e 's/targetSdk [0-9]*/targetSdk 36/' \
  "$love/app/build.gradle" "$love/love/build.gradle"
sed -i 's/com\.android\.tools\.build:gradle:[0-9.]*/com.android.tools.build:gradle:8.10.1/' "$love/build.gradle"
sed -i 's/gradle-[0-9.]*-bin\.zip/gradle-8.11.1-bin.zip/' "$love/gradle/wrapper/gradle-wrapper.properties"
mk="$love/love/src/jni/Application.mk"
sed -i 's/^APP_PLATFORM := .*/APP_PLATFORM := 21/' "$mk"
grep -q FLEXIBLE_PAGE_SIZES "$mk" || printf 'APP_SUPPORT_FLEXIBLE_PAGE_SIZES := true\n' >> "$mk"
# r27 compiles C++17, where libmodplug's old `register` keyword is an error.
grep -q Wno-register "$mk" || printf 'APP_CPPFLAGS += -Wno-register\n' >> "$mk"
# r27 also drops ALooper_pollAll. SDL itself moved to ALooper_pollOnce, which acts
# the same for a check that doesn't wait.
{ grep -rl ALooper_pollAll "$love/love/src/jni/SDL2/src" || true; } | xargs -r sed -i 's/ALooper_pollAll(/ALooper_pollOnce(/g'
# The love library shrinks itself with no rules, and the newer R8 then strips the
# constructor Android needs to start GameActivity. Keep what the app keeps.
rules="$love/love/proguard-rules.pro"
grep -q 'org.love2d.android' "$rules" || printf '%s\n' '-keep class org.love2d.android.** { *; }' \
  '-keep class org.libsdl.app.** { *; }' >> "$rules"

# The noRecord flavour drops the microphone permission with this manifest, but
# love-android keeps it in src/norecord, which Gradle only finds on a filesystem
# that ignores case. SPPPD never records.
mkdir -p "$love/app/src/noRecord"
cp "$love/app/src/norecord/AndroidManifest.xml" "$love/app/src/noRecord/"

assets="$love/app/src/embed/assets"
mkdir -p "$assets"
rm -f "$assets/game.love"
if [ $# -gt 0 ]; then
  cp "$1" "$assets/game.love"
else
  (cd "$repo" && zip -q -9 -r -X "$assets/game.love" main.lua conf.lua LICENSE assets src)
fi
echo "love-android ready: SPPPD $ver ($code)"
