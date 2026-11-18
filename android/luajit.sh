#!/usr/bin/env bash
# Rebuilds LuaJIT for Android from the source love-android ships, replacing its
# prebuilt libluajit.so and .a for each ABI the APK carries. F-Droid deletes those prebuilt
# files and runs this instead; make apk keeps them.
#
# Follows megasource's LuaJIT/android_build_readme.bat, on Linux. Needs the
# Android NDK (pass its path, or set ANDROID_NDK_HOME) and a gcc that can build
# 32-bit programs (gcc-multilib on Debian), since the ARMv7 build runs a 32-bit
# helper on the build machine.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
luajit="$repo/android/love-android/app/src/main/cpp/megasource/libs/LuaJIT"
ndk=${1:-${ANDROID_NDK_HOME:-${ANDROID_HOME:-$HOME/Android/Sdk}/ndk/27.1.12297006}}
bin="$ndk/toolchains/llvm/prebuilt/linux-x86_64/bin"
[ -x "$bin/clang" ] || { echo "No NDK at $ndk"; exit 1; }

# abi, clang target, Android API (the APK needs 24, Android 7.0), host gcc flags
build() {
  local abi=$1 target=$2 api=$3 host=$4
  make -C "$luajit" clean >/dev/null
  make -C "$luajit" -j"$(nproc)" \
    HOST_CC="gcc $host" \
    CROSS="$bin/$target-" \
    STATIC_CC="$bin/$target$api-clang -fPIC" \
    DYNAMIC_CC="$bin/$target$api-clang -fPIC" \
    TARGET_LD="$bin/$target$api-clang" \
    TARGET_LDFLAGS=-fuse-ld=lld \
    TARGET_AR="$bin/llvm-ar rcus" \
    TARGET_STRIP="$bin/llvm-strip" \
    TARGET_SYS=Linux \
    TARGET_SONAME=libluajit.so \
    CCDEBUG=-g \
    amalg
  local out="$luajit/android/$abi"
  rm -rf "$out"
  mkdir -p "$out"
  cp "$luajit/src/libluajit.a" "$luajit/src/libluajit.so" "$luajit/src/luajit.h" "$out/"
  cp -r "$luajit/src/jit" "$out/jit"
  rm -f "$out/jit/.gitignore"
}

build arm64-v8a aarch64-linux-android 24 ""
build armeabi-v7a armv7a-linux-androideabi 24 -m32
build x86_64 x86_64-linux-android 24 ""
make -C "$luajit" clean >/dev/null
ls -la "$luajit"/android/*/libluajit.so
