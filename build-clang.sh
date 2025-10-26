#!/bin/bash

# Clean everything before start
rm -rf .
rm -rf .repo
rm -rf llvm-build
echo "Cleaning completed"

# Setup LLVM build environment
echo "Creating LLVM directory. . ."
mkdir llvm-build

# Working
pushd llvm-build
rm -rf *
git clone https://github.com/nekoshirro/Alchemist-Toolchain.git clang-21 toolchains --depth 1
cd toolchains
chmod +x build-tc.sh
./build-tc.sh
echo "Toolchain build completed. Exiting directory. . ."

# Cleaning
popd
rm -rf llvm-build
