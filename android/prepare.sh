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
