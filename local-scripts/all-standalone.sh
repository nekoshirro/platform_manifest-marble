#!/bin/bash
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || exit 1

# ==============================================================================
# 1. UBUNTU-SSH / RUNNER ENVIRONMENT AUTO-PREPARATION
# ==============================================================================

echo "==========================================================="
echo " [Re]Shinomiya Kernel - Standalone Build Suite"
echo " Target Device : Redmi Note 12 Turbo / POCO F5 (marble)"
echo " SoC Platform  : Qualcomm Snapdragon 7+ Gen 2 (SM7475 Waipio - 5.10)"
echo " Environment   : Standalone / Ubuntu-SSH Compatible"
echo "==========================================================="

# Check disk space on root filesystem (clean GitHub runner bloatware if < 35 GB free)
FREE_DISK_GB=$(df -BG / | awk 'NR==2 {gsub(/G/,"",$4); print $4}')
if [ "${FREE_DISK_GB:-0}" -lt 35 ]; then
    echo ""
    echo "⚠️  Free disk space is low (${FREE_DISK_GB} GB free)."
    echo "🧹 Detected runner environment. Cleaning up unused SDKs & caches to free ~40 GB..."
    if command -v sudo >/dev/null 2>&1; then
        sudo rm -rf /usr/local/lib/android /usr/share/dotnet /opt/ghc /usr/local/share/boost /usr/share/swift "$AGENT_TOOLSDIRECTORY" 2>/dev/null || true
        sudo docker image prune -a -f 2>/dev/null || true
    else
        rm -rf /usr/local/lib/android /usr/share/dotnet /opt/ghc /usr/local/share/boost /usr/share/swift "$AGENT_TOOLSDIRECTORY" 2>/dev/null || true
    fi
    NEW_FREE_GB=$(df -BG / | awk 'NR==2 {gsub(/G/,"",$4); print $4}')
    echo "✅ Disk cleanup complete. Free disk space is now: ${NEW_FREE_GB} GB."
fi

# Check and install build dependencies if missing
REQUIRED_CMDS=("bc" "bison" "flex" "make" "gcc" "g++" "zip" "jq" "wget" "curl" "rsync" "dtc")
NEEDS_INSTALL=0
for cmd in "${REQUIRED_CMDS[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        NEEDS_INSTALL=1
        break
    fi
done
if [ ! -f /usr/include/libelf.h ] 2>/dev/null; then
    NEEDS_INSTALL=1
fi

if [ "$NEEDS_INSTALL" -eq 1 ]; then
    echo ""
    echo "📦 Required build tools are missing. Installing dependencies via apt..."
    if command -v sudo >/dev/null 2>&1; then
        sudo apt-get update -y
        sudo apt-get install -y --no-install-recommends \
            bc bison build-essential ccache curl flex \
            git git-lfs libelf-dev libssl-dev python3 \
            zip jq wget tar rsync device-tree-compiler kmod
        git lfs install 2>/dev/null || true
    else
        echo "WARNING: sudo not available, skipping apt-get install."
    fi
fi

# Ensure 20 GB Swap is allocated for Full LTO linking
SWAP_TOTAL=$(free -m | awk '/Swap:/ {print $2}')
if [ "${SWAP_TOTAL:-0}" -lt 16000 ]; then
    echo ""
    echo "💾 Current swap is ${SWAP_TOTAL:-0} MB. Setting up 20 GB swap file for Full LTO..."
    if command -v sudo >/dev/null 2>&1; then
        sudo swapoff -a 2>/dev/null || true
        sudo rm -f /swapfile 2>/dev/null || true
        if ! sudo fallocate -l 20G /swapfile 2>/dev/null; then
            echo "fallocate failed, creating swap with dd..."
            sudo dd if=/dev/zero of=/swapfile bs=1M count=20480 status=progress
        fi
        sudo chmod 600 /swapfile
        sudo mkswap /swapfile
        sudo swapon /swapfile
        sudo sysctl -w vm.swappiness=100 >/dev/null 2>&1 || true
        sudo sysctl -w vm.vfs_cache_pressure=50 >/dev/null 2>&1 || true
    else
        swapoff -a 2>/dev/null || true
        rm -f /swapfile 2>/dev/null || true
        if ! fallocate -l 20G /swapfile 2>/dev/null; then
            echo "fallocate failed, creating swap with dd..."
            dd if=/dev/zero of=/swapfile bs=1M count=20480 status=progress
        fi
        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile
        sysctl -w vm.swappiness=100 >/dev/null 2>&1 || true
        sysctl -w vm.vfs_cache_pressure=50 >/dev/null 2>&1 || true
    fi
    echo "✅ 20 GB swap activated."
fi

# ==============================================================================
# 2. SELECT BUILD VARIANTS
# ==============================================================================

BASE_URL="https://raw.githubusercontent.com/nekoshirro/platform_manifest-marble/refs/heads/kernel/local-scripts"
ROOT_RAW_URL="https://raw.githubusercontent.com/nekoshirro/platform_manifest-marble/refs/heads/kernel"
TARGET="${1:-all}"

case "$TARGET" in
    "non-root"|"non-root.sh"|"non-root-standalone.sh")
        BUILD_VARIANTS=("non-root-standalone.sh")
        ;;
    "resukisu"|"resukisu.sh"|"resukisu-standalone.sh")
        BUILD_VARIANTS=("resukisu-standalone.sh")
        ;;
    "kernelsu-next"|"ksun"|"kernelsu-next.sh"|"kernelsu-next-standalone.sh")
        BUILD_VARIANTS=("kernelsu-next-standalone.sh")
        ;;
    "sukisu"|"sukisu-ultra"|"sukisu.sh"|"sukisu-standalone.sh")
        BUILD_VARIANTS=("sukisu-standalone.sh")
        ;;
    "all"|*)
        BUILD_VARIANTS=(
            "non-root-standalone.sh"
            "resukisu-standalone.sh"
            "kernelsu-next-standalone.sh"
            "sukisu-standalone.sh"
        )
        ;;
esac

TOTAL_VARIANTS=${#BUILD_VARIANTS[@]}
CURRENT_INDEX=0
FAILED_VARIANTS=()
ALL_START_TIME=$(date +%s)

echo ""
echo "==========================================================="
echo " Starting Build Suite ($TOTAL_VARIANTS variant(s))"
echo " Time: $(TZ="Asia/Jakarta" date +'%Y-%m-%d %H:%M:%S WIB')"
echo "==========================================================="

# ==============================================================================
# 3. EXECUTION LOOP
# ==============================================================================

for script in "${BUILD_VARIANTS[@]}"; do
    CURRENT_INDEX=$((CURRENT_INDEX + 1))
    echo ""
    echo "==========================================================="
    echo " [$CURRENT_INDEX/$TOTAL_VARIANTS] Preparing $script"
    echo " Time: $(TZ="Asia/Jakarta" date +'%Y-%m-%d %H:%M:%S WIB')"
    echo "==========================================================="

    SCRIPT_PATH="$SCRIPT_DIR/$script"
    if [ ! -f "$SCRIPT_PATH" ]; then
        ALT_NAME="${script%-standalone.sh}.sh"
        if [ -f "$SCRIPT_DIR/$ALT_NAME" ]; then
            SCRIPT_PATH="$SCRIPT_DIR/$ALT_NAME"
        else
            echo "📥 Script $script not found locally. Downloading from GitHub..."
            if ! curl -fsSL -L "$BASE_URL/$script" -o "$SCRIPT_PATH" 2>/dev/null; then
                if ! curl -fsSL -L "$ROOT_RAW_URL/$ALT_NAME" -o "$SCRIPT_PATH" 2>/dev/null; then
                    wget -qO "$SCRIPT_PATH" "$BASE_URL/$script" 2>/dev/null || wget -qO "$SCRIPT_PATH" "$ROOT_RAW_URL/$ALT_NAME" 2>/dev/null || true
                fi
            fi
        fi
    fi

    if [ ! -f "$SCRIPT_PATH" ] || [ ! -s "$SCRIPT_PATH" ]; then
        echo "ERROR: Script not found and failed to download: $script"
        FAILED_VARIANTS+=("$script")
        continue
    fi

    chmod +x "$SCRIPT_PATH"

    # Clean previous kernel tree and AnyKernel3 before variant build
    # to avoid git branch switching conflicts and free up disk space
    echo "Cleaning kernel working tree and AnyKernel3 prior to variant build..."
    rm -rf "$SCRIPT_DIR/kernel/xiaomi/marble"
    rm -rf "$SCRIPT_DIR/AnyKernel3"

    echo "Executing $SCRIPT_PATH..."
    if "$SCRIPT_PATH"; then
        echo "[$CURRENT_INDEX/$TOTAL_VARIANTS] SUCCESS: $script completed successfully."
    else
        echo "[$CURRENT_INDEX/$TOTAL_VARIANTS] ERROR: $script failed with exit status $?"
        FAILED_VARIANTS+=("$script")
    fi
done

# ==============================================================================
# 4. FINAL REPORT
# ==============================================================================

ALL_DURATION=$(( $(date +%s) - ALL_START_TIME ))
echo ""
echo "==========================================================="
echo " Build Suite Finished!"
echo " Total Duration: $((ALL_DURATION / 60)) minutes $((ALL_DURATION % 60)) seconds"
echo "==========================================================="

if [ ${#FAILED_VARIANTS[@]} -gt 0 ]; then
    echo "❌ The following variant(s) failed to build:"
    for failed in "${FAILED_VARIANTS[@]}"; do
        echo "  - $failed"
    done
    exit 1
else
    echo "✅ All $TOTAL_VARIANTS variant(s) built and packaged successfully!"
    exit 0
fi
