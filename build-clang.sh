#!/bin/bash

set -e

msg() { echo -e "\e[1;32m$*\e[0m"; }
err() { echo -e "\e[1;41m$*\e[0m"; exit 1; }

SECRETS_FILE="$HOME/.secrets"
[[ -f "$SECRETS_FILE" ]] || err "~/.secrets not found!"
# shellcheck source=/dev/null
set -a          # auto-export everything sourced below
source "$SECRETS_FILE"
set +a

# ====================================================================
# Alchemist LLVM — sequential build runner
# Builds clang-21 → 22 → 23 → 24 one at a time.
# Each version uploads its asset into the SAME GitHub Release (1 tag
# per day, 4 assets inside). The first version to finish creates the
# release; the rest just append to it.
# ====================================================================

CLANG_VERSIONS=(21 22 23 24)

BUILD_ROOT="$(pwd)/llvm-build"

for VER in "${CLANG_VERSIONS[@]}"; do
    BRANCH="clang-${VER}-LTO"

    msg "========================================================"
    msg " Starting build: clang-${VER} (branch: ${BRANCH})"
    msg "========================================================"

    # Fresh workspace for every version
    rm -rf "$BUILD_ROOT"
    mkdir -p "$BUILD_ROOT"
    pushd "$BUILD_ROOT"

    git clone https://github.com/nekoshirro/Alchemist-Toolchain.git \
        -b "$BRANCH" toolchains --depth 1 \
        || err "Failed to clone branch $BRANCH"

    cd toolchains
    chmod +x build-tc.sh

    # build-tc.sh already handles:
    #   - compiling LLVM + binutils
    #   - packaging as Alchemist-LLVM-<VER>-<date>.tar.xz
    #   - gh release create (first run) or gh release upload (subsequent)
    ./build-tc.sh \
        || err "build-tc.sh failed for clang-${VER}"

    msg "clang-${VER} done. Cleaning up..."
    popd
    rm -rf "$BUILD_ROOT"

    msg "========================================================"
    msg " clang-${VER} uploaded. Moving to next version..."
    msg "========================================================"
done

msg "All done! clang 21/22/23/24 are in one GitHub Release."
msg "Check: https://github.com/nekoshirro/Alchemist-LLVM/releases"
