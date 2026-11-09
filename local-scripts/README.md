# Standalone Kernel Build Suite

Scripts for building [Re]Shinomiya kernel for Xiaomi Redmi Note 12 Turbo / POCO F5 (marble, SM7475, Linux 5.10).

These scripts are designed to run directly on an Ubuntu/Debian x86_64 system or a remote Ubuntu runner via SSH without needing full Android source tree syncs.

## Available Scripts

- all-standalone.sh: Main runner script. Installs build dependencies, configures swap, and runs builds sequentially.
- non-root-standalone.sh: Builds the vanilla non-root kernel variant (branch 17).
- resukisu-standalone.sh: Builds the ReSukiSU root variant (branch resukisu-staging).
- kernelsu-next-standalone.sh: Builds the KernelSU-Next root variant (branch ksu-next-staging).
- evo-kernel-standalone.sh: Builds the Evolution-X kernel variant.

Note: Running `./all-standalone.sh` without arguments (or with `all`) builds the three standard variants: non-root, resukisu, and kernelsu-next. SukiSU is deprecated and removed. The evo-kernel variant is built separately when explicitly specified.

## Usage

Run the master script directly from the local directory:

```bash
# Build all standard variants (non-root, resukisu, kernelsu-next):
./all-standalone.sh

# Build a single variant:
./all-standalone.sh non-root
./all-standalone.sh resukisu
./all-standalone.sh kernelsu-next
./all-standalone.sh evo

# Build multiple specific variants:
./all-standalone.sh ksun resukisu
./all-standalone.sh vanilla evo
```

### Variant Aliases

The script recognizes the following shorthand aliases:
- non-root: vanilla, nonroot
- resukisu: resuki
- kernelsu-next: ksun, ksu, kernelsu
- evo-kernel: evo, evox

## Environment and Behavior

1. Toolchain: Clang toolchains are downloaded and cached automatically under toolchain/.
2. Disk and Dependencies: Required packages (bc, bison, flex, libelf-dev, ccache, etc.) are installed automatically if missing.
3. Clean Tree: The kernel working tree is cleaned between variant builds to prevent artifact leakage and conserve disk space.
4. Notifications: Build status and output AnyKernel3 zip files are sent to Telegram if bot credentials are configured in ~/.secrets. Only failure logs are uploaded on error.
