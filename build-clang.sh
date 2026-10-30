#!/bin/bash

set -e

msg() {
    echo -e "\e[1;32m$*\e[0m"
}

err() {
    echo -e "\e[1;41m$*\e[0m" >&2
    exit 1
}

SECRETS_FILE="$HOME/.secrets"
[[ -f "$SECRETS_FILE" ]] || err "~/.secrets not found!"

set -a
source "$SECRETS_FILE"
set +a

BUILD_ROOT="$(pwd)/llvm-build"
TARGET_VERSIONS=(${*:-22})
VERSIONS_DISPLAY="${TARGET_VERSIONS[*]}"

msg "========================================================"
msg " Launching Alchemist LLVM Toolchain Pipeline: Clang ${VERSIONS_DISPLAY}"
msg "========================================================"

rm -rf "$BUILD_ROOT"
mkdir -p "$BUILD_ROOT"
pushd "$BUILD_ROOT"

git clone https://github.com/nekoshirro/Alchemist-Toolchain.git toolchains --depth 1 || err "Failed to clone Alchemist-Toolchain"

cd toolchains
chmod +x build-tc.sh

./build-tc.sh "${TARGET_VERSIONS[@]}" || err "build-tc.sh failed during pipeline execution"

popd
rm -rf "$BUILD_ROOT"

msg "========================================================"
msg " Clang ${VERSIONS_DISPLAY} pipeline finished successfully!"
msg " Check: https://github.com/nekoshirro/Alchemist-LLVM/releases"
msg "========================================================"
