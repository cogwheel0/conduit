#!/usr/bin/env bash
# Rust stable + cargo-ndk 4.1.2 + Android NDK 29; source and dependency lock pinned.
set -euo pipefail
project="$(cd "$(dirname "$0")/../.." && pwd)"
source_dir="$project/.dart_tool/phonon-runtime"
revision=49b9033e44ab0fbb935973eca3213757644d1bbb
if [[ ! -d "$source_dir/.git" ]]; then
  git clone https://github.com/gradium-ai/xn-ptts.git "$source_dir"
fi
git -C "$source_dir" checkout --detach "$revision"
: "${ANDROID_NDK_HOME:?Set ANDROID_NDK_HOME to Android NDK 29}"
rustup target add aarch64-linux-android
# Generic kernels are safe on ARM64 devices without dotprod/fp16.
export CARGO_TARGET_AARCH64_LINUX_ANDROID_RUSTFLAGS='-C strip=symbols -C link-arg=-Wl,-z,max-page-size=16384 -C target-cpu=generic'
unset RUSTFLAGS CARGO_ENCODED_RUSTFLAGS
(cd "$source_dir" && cargo ndk -t arm64-v8a -o android/jniLibs build --locked --release -p ptts-ffi)
output="$project/android/app/src/main/jniLibs/arm64-v8a"
mkdir -p "$output"
cp "$source_dir/android/jniLibs/arm64-v8a/libptts_ffi.so" "$output/"
shasum -a 256 "$output/libptts_ffi.so"
python3 "$project/scripts/voice/prepare_phonon_pack.py"
