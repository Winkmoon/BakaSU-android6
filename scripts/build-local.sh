#!/usr/bin/env bash
# Reproducible local build helper for this repository.
#
# The upstream justfile uses `cross`, which requires a container runtime.
# This script uses the installed Android NDK directly through cargo-ndk and
# the locally available Gradle distribution instead.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

export RUSTUP_HOME="${RUSTUP_HOME:-/opt/rust/rustup}"
export CARGO_HOME="${CARGO_HOME:-/opt/rust/cargo}"
export ANDROID_HOME="${ANDROID_HOME:-/opt/android-sdk}"
export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$ANDROID_HOME}"
export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-$(find "$ANDROID_HOME/ndk" -mindepth 1 -maxdepth 1 -type d | sort -V | tail -1)}"
export JAVA_HOME="${JAVA_HOME:-/opt/jdk-25}"
export PATH="$CARGO_HOME/bin:$JAVA_HOME/bin:$PATH"

# The manager supports Android 6.0 (API 23), arm64/armv7/x86_64.
ABIS="${ABIS:-arm64-v8a armeabi-v7a x86_64}"
API_LEVEL="${API_LEVEL:-23}"
GRADLE_TASK="${GRADLE_TASK:-:app:assembleDebug}"

abi_to_target() {
    case "$1" in
        arm64-v8a) echo "aarch64-linux-android" ;;
        armeabi-v7a) echo "armv7-linux-androideabi" ;;
        x86_64) echo "x86_64-linux-android" ;;
        *) echo "unsupported ABI: $1" >&2; return 1 ;;
    esac
}

abi_to_asset_dir() {
    case "$1" in
        arm64-v8a) echo "aarch64" ;;
        armeabi-v7a) echo "arm" ;;
        x86_64) echo "x86_64" ;;
        *) echo "unsupported ABI: $1" >&2; return 1 ;;
    esac
}

# ksuinit is embedded into ksud and is also used by boot patching. Build it
# first so the ksud rust-embed step sees it.
#
# The locally installed NDK bundles a libc.a that already contains Rust std,
# so the upstream +crt-static link fails with duplicate Rust symbols here.
# A dynamically linked ksuinit is used instead; the Android linker and libc
# are available in the init environment.
unset RUSTFLAGS
pushd "$ROOT_DIR/userspace/ksuinit" >/dev/null
for abi in $ABIS; do
    target="$(abi_to_target "$abi")"
    asset_dir="$(abi_to_asset_dir "$abi")"
    cargo ndk -P "$API_LEVEL" -t "$abi" build --release
    install -D -m 0755 "target/$target/release/ksuinit" \
        "$ROOT_DIR/userspace/ksud/bin/$asset_dir/ksuinit"
done
popd >/dev/null

# cargo-ndk needs to run from the crate directory.
export KSU_ANDROID_API_LEVEL="$API_LEVEL"
pushd "$ROOT_DIR/userspace/ksud" >/dev/null
for abi in $ABIS; do
    target="$(abi_to_target "$abi")"
    cargo ndk -P "$API_LEVEL" -t "$abi" build --release
    mkdir -p "$ROOT_DIR/manager/app/src/main/jniLibs/$abi"
    cp "target/$target/release/ksud" "$ROOT_DIR/manager/app/src/main/jniLibs/$abi/libksud.so"
done
popd >/dev/null

# The SDK's CMake binaries are x86_64-only; on aarch64 hosts use the system CMake.
if [ ! -f "$ROOT_DIR/manager/local.properties" ]; then
    {
        echo "sdk.dir=$ANDROID_HOME"
        if [ "$(uname -m)" = "aarch64" ] && [ -x /usr/bin/cmake ]; then
            echo "cmake.dir=/usr"
        fi
    } > "$ROOT_DIR/manager/local.properties"
fi

export LOCAL_NDK_VERSION="${LOCAL_NDK_VERSION:-$(basename "$ANDROID_NDK_HOME")}"
if [ -z "${LOCAL_BUILD_TOOLS_VERSION:-}" ]; then
    LOCAL_BUILD_TOOLS_VERSION="$(find "$ANDROID_HOME/build-tools" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -V | tail -1)"
fi
export LOCAL_BUILD_TOOLS_VERSION

GRADLE_BIN="${GRADLE_BIN:-}"
if [ -z "$GRADLE_BIN" ]; then
    cached="$(find "$HOME/.gradle/wrapper/dists" -path '*/gradle-9.7.1/bin/gradle' -type f 2>/dev/null | head -1)"
    if [ -n "$cached" ]; then
        GRADLE_BIN="$cached"
    else
        GRADLE_BIN="$ROOT_DIR/manager/gradlew"
    fi
fi

cd "$ROOT_DIR/manager"
"$GRADLE_BIN" "$GRADLE_TASK" --no-configuration-cache \
    -I "$ROOT_DIR/scripts/local-sdk-overrides.gradle"
