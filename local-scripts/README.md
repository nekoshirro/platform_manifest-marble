# [Re]Shinomiya Kernel - Standalone Build Suite

Standalone kernel compilation suite for **Xiaomi Redmi Note 12 Turbo / POCO F5 (`marble`)** powered by Qualcomm Snapdragon 7+ Gen 2 (Waipio - SM7475 - 5.10).

Designed for direct execution on **Ubuntu-SSH** (GitHub Actions runner via SSH) or any Ubuntu/Debian x86_64 environment.

---

## 🚀 Available Build Scripts

| Script | Root Solution | Branch | Output Zip Format |
|---|---|---|---|
| `all-standalone.sh` | **Ubuntu-SSH Master Orchestrator** | - | Cleans bloatware, sets 20G swap, installs deps, and builds all variants sequentially |
| `non-root-standalone.sh` | Non-root (Vanilla) | `17` | `[Re]Shinomiya-marble-5.10.x-<date>-<time>.zip` |
| `resukisu-standalone.sh` | ReSukiSU | `resukisu-staging` | `[Re]Shinomiya-marble-5.10.x-<date>-<time>-ReSukiSU.zip` |
| `kernelsu-next-standalone.sh` | KernelSU-Next | `ksu-next-staging` | `[Re]Shinomiya-marble-5.10.x-<date>-<time>-KSUN.zip` |
| `sukisu-standalone.sh` | SukiSU-Ultra (with KPM) | `sukisu-staging` | `[Re]Shinomiya-marble-5.10.x-<date>-<time>-SukiSU.zip` |

---

## ⚡ Quick Start on Ubuntu-SSH

After connecting to the runner via SSH (`runner@...`):

```bash
# 1. Clone this repository
git clone https://github.com/nekoshirro/kernel-build_marble.git
cd kernel-build_marble

# 2. Build all variants sequentially:
./all-standalone.sh

# Or build a specific variant:
./all-standalone.sh sukisu
./all-standalone.sh ksun
./all-standalone.sh resukisu
./all-standalone.sh non-root
```

### What `all-standalone.sh` does automatically:
1. **Runner Bloatware Cleanup**: Removes Android SDK, .NET, Swift, and Docker pre-installed caches to free up $\approx 40\text{ GB}$ (leaving $\approx 55\text{ GB}$ free disk space).
2. **Dependency Installation**: Automatically installs missing toolchain packages (`bc`, `bison`, `flex`, `libelf-dev`, `ccache`, `kmod`, etc.).
3. **20 GB Swap Allocation**: Instantly allocates 20 GB swap using `fallocate` so Full LTO (`vmlinux.o`) never gets killed by OOM.
4. **Automated Sequential Build**: Runs each variant one by one (Telegram notifications and AnyKernel3 `.zip` uploads are handled directly by each variant script), cleaning the kernel tree in between builds to preserve disk space.
5. **Dynamic Clang Toolchain Management**: Automatically resolves and downloads the latest **Alchemist LLVM Clang 23** release from GitHub (`nekoshirro/Alchemist-LLVM`), caching the toolchain across variant builds and reporting the exact compiler version in Telegram notifications.
