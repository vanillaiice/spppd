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

if [ ! -f "$love/app/src/main/cpp/love/CMakeLists.txt" ]; then
  git -C "$repo" submodule update --init --recursive --depth 1 android/love-android
fi

sed -i -e 's/^app\.name\(_byte_array\)\?=.*/app.name=SPPPD/' \
  -e 's/^app\.application_id=.*/app.application_id=xyz.spppd/' \
  -e "s/^app\.version_code=.*/app.version_code=$code/" \
  -e "s/^app\.version_name=.*/app.version_name=$ver/" "$love/gradle.properties"

cp -r "$repo/android/res/." "$love/app/src/main/res/"

# Gradle's default 512 MB ran out packaging the APK once.
grep -q '^org.gradle.jvmargs=' "$love/gradle.properties" ||
  printf 'org.gradle.jvmargs=-Xmx2g\n' >> "$love/gradle.properties"

# LÖVE 12's love-android asks for NDK r30 and API 37. The NDK every SPPPD build
# uses (and F-Droid's recipe names) is r27, which builds it as well, and API 36 is
# what Google Play asks for now. Both build native code for 16 KB memory pages.
sed -i -e "s/ndkVersion '[^']*'/ndkVersion '$NDK_VERSION'/" \
  -e 's/compileSdk [0-9]*/compileSdk 36/' -e 's/targetSdk [0-9]*/targetSdk 36/' "$love/app/build.gradle"

# Phones only (x86_64 is for emulators), and the libraries compressed in the APK
# as in 3.x: stored plain, as Android 7.0 and up would take them, the APK is seven
# times the size to download.
sed -i "s/abiFilters 'armeabi-v7a', 'arm64-v8a', 'x86_64'/abiFilters 'armeabi-v7a', 'arm64-v8a'/" "$love/app/build.gradle"
grep -q "abiFilters 'armeabi-v7a', 'arm64-v8a'$" "$love/app/build.gradle"
grep -q useLegacyPackaging "$love/app/build.gradle" ||
  printf '\nandroid.packaging.jniLibs.useLegacyPackaging = true\n' >> "$love/app/build.gradle"

# The safe area is the camera notch alone, as on LÖVE 11. SDL 3 also counts the
# strips along every edge that a swipe works from, which on an A04 kept 24 to 54
# dp clear on all four sides and left the menu board short of the top and bottom.
sdl_surface="$love/app/src/main/cpp/megasource/libs/SDL3/android-project/app/src/main/java/org/libsdl/app/SDLSurface.java"
sed -z -i 's/getInsets(WindowInsets\.Type\.systemBars()[^;]*WindowInsets\.Type\.displayCutout())/getInsets(WindowInsets.Type.displayCutout())/' "$sdl_surface"
grep -q 'getInsets(WindowInsets.Type.displayCutout())' "$sdl_surface"

# SPPPD never records, so the noRecord flavour drops the microphone permission
# LÖVE's manifest asks for.
mkdir -p "$love/app/src/noRecord"
cp "$repo/android/noRecord/AndroidManifest.xml" "$love/app/src/noRecord/"

assets="$love/app/src/embed/assets"
mkdir -p "$assets"
rm -f "$assets/game.love"
if [ $# -gt 0 ]; then
  cp "$1" "$assets/game.love"
else
  (cd "$repo" && zip -q -9 -r -X "$assets/game.love" main.lua conf.lua LICENSE assets src)
fi
echo "love-android ready: SPPPD $ver ($code)"
