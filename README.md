# Kernel Build Automation Script

A comprehensive automated script for cloning, patching, and compiling Android kernels. This project supports various Kernel-level Root (SU) solutions and integrates with AnyKernel3 for flashable zip generation.

Developed by [@nekoshirro](https://github.com/nekoshirro).

---

## Features

* **Full Source Management**: Automatic cloning and environment setup.
* **Multi-SU Integration**: Built-in support for patching:
    * KernelSU
    * KernelSU-Next
    * ReSukiSU
    * SukiSU-Ultra
    * MamboSU
* **Compiler Support**: Optimized for Latest AOSP Clang with support for custom toolchains.
* **Automated Packaging**: Generates `Image`, `dtb`, `dtbo`, and a ready-to-flash AnyKernel3 `.zip`.

---

## Credits

This project is maintained by:
* **Main Developer**: [@nekoshirro](https://github.com/nekoshirro)
* **Tools**: AnyKernel3 by osm0sis, AOSP Clang by Google.

---

## Prerequisites

Ensure your build environment has the necessary dependencies installed:

```bash
sudo apt-get update
sudo apt-get install git-core gnupg flex bison build-essential zip curl zlib1g-dev \
                     libncurses5-dev libssl-dev bc libelf-dev llvm lld
