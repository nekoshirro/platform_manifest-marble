#!/bin/bash
set -o pipefail

ROOT_DIR="$PWD"
LOG_FILE="$ROOT_DIR/log.txt"
: > "$LOG_FILE"

for sec in "/tmp/src/android/.secrets" "$HOME/.secrets" "$ROOT_DIR/.secrets"; do
    [ -f "$sec" ] && source "$sec"
done

export DEVICE_CODE="marble"
export DEVICE_DISPLAY="Redmi Note 12 Turbo"
export DEVICE_NAME="Redmi Note 12 Turbo"
export KERNEL_NAME="Evolution-X"
export ROOT_VARIANT="Non-root"
export COMPILER_NAME="Google Clang AOSP (r563880c)"
export TZ="Asia/Jakarta"
export ARCH="arm64"
export SUBARCH="arm64"

send_telegram() {
    local chat_id="$1"
    local message="$2"
    [ -z "$TG_BOT_TOKEN" ] && return 0
    [ -z "$chat_id" ] && return 0
    curl -s --max-time 20 -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${chat_id}" \
        --data-urlencode "text=${message}" \
        -d "parse_mode=HTML" \
        -d "disable_web_page_preview=true" > /dev/null
}

send_document() {
    local chat_id="$1"
    local file_path="$2"
    local caption="$3"
    local filename
    filename=$(basename "$file_path")
    local mime="application/octet-stream"
    [[ "$filename" == *.zip ]] && mime="application/zip"
    [[ "$filename" == *.txt ]] && mime="text/plain"
    local resp
    [ -z "$TG_BOT_TOKEN" ] && return 0
    [ -z "$chat_id" ] && return 0
    [ ! -f "$file_path" ] && return 1
    resp=$(curl -s --max-time 300 \
        --form-string "chat_id=${chat_id}" \
        --form-string "caption=${caption}" \
        --form-string "parse_mode=HTML" \
        -F "document=@${file_path};filename=${filename};type=${mime}" \
        "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendDocument")
    if echo "$resp" | grep -q '"ok":true'; then
        return 0
    fi
    echo "WARNING: sendDocument failed: ${resp:0:200}" | tee -a "$LOG_FILE"
    return 1
}

TRIGGER_SENT=0
BUILD_START_TIME=$(date +%s)

die() {
    local reason="$*"
    echo "FATAL: $reason" | tee -a "$LOG_FILE"
    if [ "$TRIGGER_SENT" -eq 1 ]; then
        local dur=$(( $(date +%s) - BUILD_START_TIME ))
        local fail_msg="<b>❌ Build Failed</b>
<b>Root:</b> $ROOT_VARIANT
<b>Duration:</b> $((dur / 60)) minutes $((dur % 60)) seconds
<b>Reason:</b> <code>$reason</code>
<b>This kernel is based on Evolution-X kernel!</b>"
        if [ -f "$LOG_FILE" ] && [ -s "$LOG_FILE" ]; then
            send_document "$TG_ADMIN_CHAT_ID" "$LOG_FILE" "$fail_msg" || send_telegram "$TG_ADMIN_CHAT_ID" "$fail_msg"
        else
            send_telegram "$TG_ADMIN_CHAT_ID" "$fail_msg"
        fi
    fi
    exit 1
}

echo "Configuring virtual memory and swap..." | tee -a "$LOG_FILE"
SWAP_TOTAL=$(free -m | awk '/Swap:/ {print $2}')
if [ "${SWAP_TOTAL:-0}" -lt 16000 ]; then
    echo "Current swap is ${SWAP_TOTAL:-0} MB. Setting up 20 GB swap file..." | tee -a "$LOG_FILE"
    if command -v sudo >/dev/null 2>&1; then
        sudo swapoff -a 2>/dev/null || true
        sudo rm -f /swapfile 2>/dev/null || true
        sudo fallocate -l 20G /swapfile 2>/dev/null || sudo dd if=/dev/zero of=/swapfile bs=1M count=20480 status=progress
        sudo chmod 600 /swapfile
        sudo mkswap /swapfile 2>&1 | tee -a "$LOG_FILE"
        sudo swapon /swapfile 2>&1 | tee -a "$LOG_FILE"
        sudo sysctl -w vm.swappiness=100 >/dev/null 2>&1 || true
        sudo sysctl -w vm.vfs_cache_pressure=50 >/dev/null 2>&1 || true
    else
        swapoff -a 2>/dev/null || true
        rm -f /swapfile 2>/dev/null || true
        fallocate -l 20G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=20480 status=progress
        chmod 600 /swapfile
        mkswap /swapfile 2>&1 | tee -a "$LOG_FILE"
        swapon /swapfile 2>&1 | tee -a "$LOG_FILE"
        sysctl -w vm.swappiness=100 >/dev/null 2>&1 || true
        sysctl -w vm.vfs_cache_pressure=50 >/dev/null 2>&1 || true
    fi
fi
free -h | grep -E "Mem:|Swap:" | tee -a "$LOG_FILE"

echo "Checking host build dependencies..." | tee -a "$LOG_FILE"
REQUIRED_PKGS="bc bison build-essential curl device-tree-compiler flex git git-lfs kmod libelf-dev libssl-dev python3 zip pahole"
MISSING_PKGS=""
for pkg in $REQUIRED_PKGS; do
    dpkg -s "$pkg" >/dev/null 2>&1 || MISSING_PKGS="$MISSING_PKGS $pkg"
done

if [ -n "$MISSING_PKGS" ]; then
    echo "Installing missing packages:$MISSING_PKGS" | tee -a "$LOG_FILE"
    if command -v sudo >/dev/null 2>&1; then
        sudo apt-get update -y 2>&1 | tee -a "$LOG_FILE"
        sudo apt-get install -y --no-install-recommends $MISSING_PKGS 2>&1 | tee -a "$LOG_FILE" || die "failed to install dependencies"
    else
        apt-get update -y 2>&1 | tee -a "$LOG_FILE"
        apt-get install -y --no-install-recommends $MISSING_PKGS 2>&1 | tee -a "$LOG_FILE" || die "failed to install dependencies"
    fi
fi
git lfs install 2>&1 | tee -a "$LOG_FILE"

TOOLS_DIR="$ROOT_DIR/tools"
mkdir -p "$TOOLS_DIR"
if [ ! -f "$TOOLS_DIR/merge_dtbs.py" ]; then
    echo "Downloading merge_dtbs.py..." | tee -a "$LOG_FILE"
    curl -fsSL "https://raw.githubusercontent.com/LineageOS/android_vendor_lineage/lineage-22.1/build/tools/merge_dtbs.py" -o "$TOOLS_DIR/merge_dtbs.py" || true
    [ -f "$TOOLS_DIR/merge_dtbs.py" ] && chmod +x "$TOOLS_DIR/merge_dtbs.py"
fi

if [ ! -f "$TOOLS_DIR/ufdt_apply_overlay" ] || [ ! -x "$TOOLS_DIR/ufdt_apply_overlay" ]; then
    echo "Downloading ufdt_apply_overlay..." | tee -a "$LOG_FILE"
    curl -fsSL "https://raw.githubusercontent.com/papel-palyground/android_kernel_prebuilts_build-tools/lineage-23.2/linux-x86/bin/ufdt_apply_overlay" -o "$TOOLS_DIR/ufdt_apply_overlay" || true
    [ -f "$TOOLS_DIR/ufdt_apply_overlay" ] && chmod +x "$TOOLS_DIR/ufdt_apply_overlay"
fi

if [ ! -f "$TOOLS_DIR/fdtoverlaymerge" ] || [ ! -x "$TOOLS_DIR/fdtoverlaymerge" ]; then
    echo "Downloading fdtoverlaymerge..." | tee -a "$LOG_FILE"
    curl -fsSL "https://raw.githubusercontent.com/papel-palyground/android_kernel_prebuilts_build-tools/lineage-23.2/linux-x86/bin/fdtoverlaymerge" -o "$TOOLS_DIR/fdtoverlaymerge" || true
    [ -f "$TOOLS_DIR/fdtoverlaymerge" ] && chmod +x "$TOOLS_DIR/fdtoverlaymerge"
fi

export PATH="$TOOLS_DIR:$PATH"

sync_git_repo() {
    local target_dir="$1"
    local repo_url="$2"
    local branch="$3"
    local recurse="$4"

    local need_clean_clone=0
    if [ ! -d "$target_dir/.git" ]; then
        need_clean_clone=1
    else
        local cur_branch
        cur_branch=$(git -C "$target_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
        if [ -n "$cur_branch" ] && [ "$cur_branch" != "HEAD" ] && [ "$cur_branch" != "$branch" ]; then
            echo "Branch mismatch in $(basename "$target_dir") ($cur_branch != $branch). Performing fresh clone..." | tee -a "$LOG_FILE"
            need_clean_clone=1
        fi
    fi

    if [ "$need_clean_clone" = "1" ]; then
        echo "Cloning $(basename "$target_dir") ($branch)..." | tee -a "$LOG_FILE"
        rm -rf "$target_dir"
        mkdir -p "$(dirname "$target_dir")"
        local recurse_flag=""
        [ "$recurse" = "1" ] && recurse_flag="--recurse-submodules"
        git clone $recurse_flag "$repo_url" -b "$branch" "$target_dir" --depth 1 2>&1 | tee -a "$LOG_FILE" || die "clone $(basename "$target_dir") failed"
    else
        echo "Checking updates for $(basename "$target_dir") ($branch)..." | tee -a "$LOG_FILE"
        git -C "$target_dir" fetch origin "$branch" --depth 1 2>&1 | tee -a "$LOG_FILE" || true
        local local_head remote_head
        local_head=$(git -C "$target_dir" rev-parse HEAD 2>/dev/null)
        remote_head=$(git -C "$target_dir" rev-parse FETCH_HEAD 2>/dev/null)
        if [ -n "$remote_head" ] && [ "$local_head" != "$remote_head" ]; then
            echo "New commits detected, updating $(basename "$target_dir")..." | tee -a "$LOG_FILE"
            git -C "$target_dir" reset --hard FETCH_HEAD 2>&1 | tee -a "$LOG_FILE"
            if [ "$recurse" = "1" ]; then
                git -C "$target_dir" submodule update --init --recursive --depth 1 2>&1 | tee -a "$LOG_FILE"
            fi
        else
            echo "$(basename "$target_dir") is up to date." | tee -a "$LOG_FILE"
            if [ "$recurse" = "1" ]; then
                git -C "$target_dir" submodule update --init --recursive --depth 1 2>&1 | tee -a "$LOG_FILE"
            fi
        fi
    fi
}

CLANG_DIR="$ROOT_DIR/toolchain/clang-r563880c"
if [ ! -f "$CLANG_DIR/.clang_ok" ] || [ ! -x "$CLANG_DIR/bin/clang" ]; then
    echo "Setting up Google Clang AOSP (r563880c)..." | tee -a "$LOG_FILE"
    rm -rf "$CLANG_DIR"
    mkdir -p "$CLANG_DIR"

    CLANG_TAR="$ROOT_DIR/toolchain/clang-r563880c.tar.gz"
    DOWNLOAD_SUCCESS=0

    # 1. Download from nekoshirro/aosp_clang-mirror private release using GH_TOKEN
    if [ -n "$GH_TOKEN" ]; then
        echo "Querying GitHub API for private Clang release asset (nekoshirro/aosp_clang-mirror:clang-21)..." | tee -a "$LOG_FILE"
        ASSET_API_URL=$(python3 -c "
import sys, json, urllib.request
token = sys.argv[1]
req = urllib.request.Request(
    'https://api.github.com/repos/nekoshirro/aosp_clang-mirror/releases/tags/clang-21',
    headers={
        'Authorization': f'Bearer {token}',
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'curl/8.0'
    }
)
try:
    with urllib.request.urlopen(req, timeout=20) as resp:
        data = json.load(resp)
        for a in data.get('assets', []):
            if a.get('name') == 'clang-r563880c.tar.gz':
                print(a.get('url'))
                break
except Exception as e:
    sys.stderr.write(f'GitHub API error: {e}\n')
" "$GH_TOKEN" 2>>"$LOG_FILE" || true)

        if [ -n "$ASSET_API_URL" ]; then
            echo "Found asset URL: $ASSET_API_URL. Downloading with GitHub Token..." | tee -a "$LOG_FILE"
            if curl -sSL --max-time 600 \
                -H "Authorization: Bearer $GH_TOKEN" \
                -H "Accept: application/octet-stream" \
                -o "$CLANG_TAR" \
                "$ASSET_API_URL" && [ -s "$CLANG_TAR" ]; then
                DOWNLOAD_SUCCESS=1
            fi
        fi

        if [ "$DOWNLOAD_SUCCESS" -ne 1 ]; then
            echo "Direct curl attempt on private release link..." | tee -a "$LOG_FILE"
            if curl -fSL --max-time 600 \
                -H "Authorization: token $GH_TOKEN" \
                -o "$CLANG_TAR" \
                "https://github.com/nekoshirro/aosp_clang-mirror/releases/download/clang-21/clang-r563880c.tar.gz" && [ -s "$CLANG_TAR" ]; then
                if ! head -c 100 "$CLANG_TAR" | grep -qE "^{|\<html"; then
                    DOWNLOAD_SUCCESS=1
                else
                    rm -f "$CLANG_TAR"
                fi
            fi
        fi
    else
        echo "Notice: No GH_TOKEN found in .secrets. Trying public mirror or direct download..." | tee -a "$LOG_FILE"
    fi

    # 2. Fallback to public AOSP Gitiles archive if needed
    if [ "$DOWNLOAD_SUCCESS" -ne 1 ]; then
        echo "Private release download unavailable, trying AOSP Gitiles..." | tee -a "$LOG_FILE"
        CLANG_TAR_URL="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/tags/android-16.0.0_r4/clang-r563880c.tar.gz"
        if curl -fSL --retry 3 --connect-timeout 30 "$CLANG_TAR_URL" -o "$CLANG_TAR" 2>&1 | tee -a "$LOG_FILE" && [ -s "$CLANG_TAR" ]; then
            DOWNLOAD_SUCCESS=1
        fi
    fi

    # Extract tarball if successfully downloaded
    if [ "$DOWNLOAD_SUCCESS" -eq 1 ] && tar -xzf "$CLANG_TAR" -C "$CLANG_DIR" 2>&1 | tee -a "$LOG_FILE" && [ -x "$CLANG_DIR/bin/clang" ]; then
        rm -f "$CLANG_TAR"
        touch "$CLANG_DIR/.clang_ok"
        echo "Clang r563880c extracted successfully." | tee -a "$LOG_FILE"
    else
        # 3. Final Fallback: Git clone from bluegreensea mirror
        echo "Tarball extraction failed, falling back to Git clone from bluegreensea mirror..." | tee -a "$LOG_FILE"
        rm -rf "$CLANG_DIR" "$CLANG_TAR"
        mkdir -p "$CLANG_DIR"
        git clone https://github.com/bluegreensea/android_prebuilts_clang_kernel_linux-x86_clang-r563880c.git -b main "$CLANG_DIR" --depth 1 2>&1 | tee -a "$LOG_FILE" || die "clone clang-r563880c failed"
        (git -C "$CLANG_DIR" lfs install && git -C "$CLANG_DIR" lfs pull) 2>&1 | tee -a "$LOG_FILE" || die "LFS pull clang-r563880c failed"
        touch "$CLANG_DIR/.clang_ok"
    fi
else
    echo "Using existing Clang r563880c toolchain in $CLANG_DIR..." | tee -a "$LOG_FILE"
fi

export PATH="$CLANG_DIR/bin:$PATH"
which clang >/dev/null 2>&1 || die "clang binary not found in $CLANG_DIR/bin"

# Sync Marble Device Trees & Platform Kernel Repositories based on evolution.dependencies
DEVICE_DIR="$ROOT_DIR/device/xiaomi/marble"
sync_git_repo "$DEVICE_DIR" "https://github.com/Evolution-X-Devices/device_xiaomi_marble.git" "cnb" "0"

COMMON_DEVICE_DIR="$ROOT_DIR/device/xiaomi/sm8450-common"
sync_git_repo "$COMMON_DEVICE_DIR" "https://github.com/Evolution-X-Devices/device_xiaomi_sm8450-common.git" "cnb-6.6" "0"

# Target platform directories matching evolution.dependencies:
# kernel/platform/kernel-6.6/vendor/xiaomi/{sm8450-kernel, sm8450-devicetrees, sm8450-modules, sm8450-build}
TARGET_KERNEL_PLATFORM_DIR="$ROOT_DIR/kernel/platform/kernel-6.6/vendor/xiaomi"
mkdir -p "$TARGET_KERNEL_PLATFORM_DIR"

KERNEL_SRC="$TARGET_KERNEL_PLATFORM_DIR/sm8450-kernel"
sync_git_repo "$KERNEL_SRC" "https://github.com/Evolution-X-Devices/kernel_xiaomi_sm8450.git" "cnb-6.6" "0"

DT_SRC="$TARGET_KERNEL_PLATFORM_DIR/sm8450-devicetrees"
sync_git_repo "$DT_SRC" "https://github.com/Evolution-X-Devices/kernel_xiaomi_sm8450-devicetrees.git" "cnb-6.6" "0"

EXT_MODULES_ROOT="$TARGET_KERNEL_PLATFORM_DIR/sm8450-modules"
sync_git_repo "$EXT_MODULES_ROOT" "https://github.com/cupid-development/android_kernel_xiaomi_sm8450-modules-6.6.git" "lineage-24.0-6.6" "0"

BUILD_SRC="$TARGET_KERNEL_PLATFORM_DIR/sm8450-build"
sync_git_repo "$BUILD_SRC" "https://github.com/cupid-development/android_kernel_xiaomi_sm8450-build-6.6.git" "lineage-24.0-6.6" "0"

# Create symlinks for backward compatibility and path expectations
mkdir -p "$ROOT_DIR/kernel/xiaomi"
ln -sfn "$KERNEL_SRC" "$ROOT_DIR/kernel/xiaomi/sm8450"
ln -sfn "$KERNEL_SRC" "$ROOT_DIR/kernel/xiaomi/marble"
ln -sfn "$DT_SRC" "$ROOT_DIR/kernel/xiaomi/sm8450-devicetrees"
ln -sfn "$DT_SRC" "$ROOT_DIR/kernel/xiaomi/marble-devicetrees"
ln -sfn "$EXT_MODULES_ROOT" "$ROOT_DIR/kernel/xiaomi/sm8450-modules"
ln -sfn "$EXT_MODULES_ROOT" "$ROOT_DIR/kernel/xiaomi/marble-modules"
ln -sfn "$BUILD_SRC" "$ROOT_DIR/kernel/xiaomi/sm8450-build"

# Link device trees and external modules inside kernel source
mkdir -p "$KERNEL_SRC/arch/arm64/boot/dts"
rm -f "$KERNEL_SRC/arch/arm64/boot/dts/vendor"
ln -sfn "$DT_SRC" "$KERNEL_SRC/arch/arm64/boot/dts/vendor"

ln -sfn "$EXT_MODULES_ROOT" "$KERNEL_SRC/sm8450-modules"
ln -sfn "$EXT_MODULES_ROOT" "$KERNEL_SRC/marble-modules"
mkdir -p "$KERNEL_SRC/out"
ln -sfn "$EXT_MODULES_ROOT" "$KERNEL_SRC/out/sm8450-modules"
ln -sfn "$EXT_MODULES_ROOT" "$KERNEL_SRC/out/marble-modules"

cd "$KERNEL_SRC" || die "failed to enter $KERNEL_SRC"

KERNEL_VERSION=$(awk '
/^VERSION/ {v=$3}
/^PATCHLEVEL/ {p=$3}
/^SUBLEVEL/ {s=$3}
END {print v "." p "." s}
' Makefile)
export KERNEL_VERSION
echo "KERNEL_VERSION=$KERNEL_VERSION" | tee -a "$LOG_FILE"

DOCKEROS=$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d '"' -f2)
[ -z "$DOCKEROS" ] && DOCKEROS="Ubuntu Linux"
DATE_EN=$(TZ="Asia/Jakarta" date +'%d %B %Y, %H:%M WIB')

START_MSG="<b>🔨Kernel Build Triggered</b>

<b>Docker OS:</b> $DOCKEROS
<b>Date:</b> $DATE_EN
<b>Device:</b> $DEVICE_NAME
<b>Codename:</b> $DEVICE_CODE
<b>Kernel Version:</b> $KERNEL_VERSION
<b>Root:</b> $ROOT_VARIANT
<b>Compiler:</b> $COMPILER_NAME
<b>This kernel is based on Evolution-X kernel!</b>"

send_telegram "$TG_ADMIN_CHAT_ID" "$START_MSG"
TRIGGER_SENT=1

BUILD_START_TIME=$(date +%s)
echo "Generating kernel configuration from BoardConfig.mk..." | tee -a "$LOG_FILE"
mkdir -p out

# Kernel 6.6 defconfig fragments for marble
CONFIG_LIST="gki_defconfig vendor/waipio_perf.config vendor/xiaomi_GKI.config vendor/marble_GKI.config"

MERGE_ARGS=""
for cfg in $CONFIG_LIST; do
    if [ -f "arch/arm64/configs/$cfg" ]; then
        MERGE_ARGS="$MERGE_ARGS arch/arm64/configs/$cfg"
    else
        die "Kernel config fragment not found: arch/arm64/configs/$cfg"
    fi
done

./scripts/kconfig/merge_config.sh -m -O out $MERGE_ARGS 2>&1 | tee -a "$LOG_FILE" || die "merge_config failed"
./scripts/config --file out/.config -d LOCALVERSION_AUTO

make -j"$(nproc --all)" ARCH=arm64 O=out LLVM=1 LLVM_IAS=1 olddefconfig 2>&1 | tee -a "$LOG_FILE" || die "olddefconfig failed"

kmake() {
    make -j"$(nproc --all)" \
        O=out \
        ARCH=arm64 \
        CC=clang \
        LD=ld.lld \
        AR=llvm-ar \
        NM=llvm-nm \
        OBJCOPY=llvm-objcopy \
        OBJDUMP=llvm-objdump \
        STRIP=llvm-strip \
        LLVM=1 \
        LLVM_IAS=1 \
        TARGET_PRODUCT=marble \
        "$@"
}

echo "Compiling Kernel Image..." | tee -a "$LOG_FILE"
kmake Image 2>&1 | tee -a "$LOG_FILE"
BUILD_STATUS=${PIPESTATUS[0]}
[ "$BUILD_STATUS" -eq 0 ] || die "Kernel Image compilation failed"

BOOT_IMG_PATH="$KERNEL_SRC/out/arch/arm64/boot/Image"
[ -f "$BOOT_IMG_PATH" ] || die "Kernel Image not found at $BOOT_IMG_PATH"

echo "Compiling Device Tree Blobs (DTBs)..." | tee -a "$LOG_FILE"
kmake dtbs 2>&1 | tee -a "$LOG_FILE" || die "DTB compilation failed"

echo "Compiling in-tree Kernel Modules..." | tee -a "$LOG_FILE"
MODULES_STAGING="$KERNEL_SRC/out/modules_staging"
rm -rf "$MODULES_STAGING"
mkdir -p "$MODULES_STAGING"

kmake modules 2>&1 | tee -a "$LOG_FILE" || die "in-tree modules compilation failed"
kmake INSTALL_MOD_PATH="$MODULES_STAGING" INSTALL_MOD_STRIP=1 modules_install 2>&1 | tee -a "$LOG_FILE" || die "in-tree modules install failed"

echo "Compiling external Kernel Modules..." | tee -a "$LOG_FILE"
find "$EXT_MODULES_ROOT" -name "Module.symvers" -delete 2>/dev/null || true
RPATH=$(python3 -c 'import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "$EXT_MODULES_ROOT" "$KERNEL_SRC")

EXT_MODULES=(
    "qcom/opensource/mmrm-driver"
    "qcom/opensource/mm-drivers/sync_fence"
    "qcom/opensource/mm-drivers/msm_ext_display"
    "qcom/opensource/securemsm-kernel"
    "qcom/opensource/spu-kernel"
    "qcom/opensource/synx-kernel"
    "qcom/opensource/synx-kernel-v1"
    "qcom/opensource/display-drivers/msm"
    "qcom/opensource/audio-kernel"
    "qcom/opensource/camera-kernel"
    "qcom/opensource/video-driver"
    "qcom/opensource/graphics-kernel"
    "qcom/opensource/dsp-kernel"
    "qcom/opensource/eva-kernel-v1"
    "qcom/opensource/wlan/platform"
    "qcom/opensource/wlan/qcacld-3.0"
    "qcom/opensource/bt-kernel"
    "qcom/opensource/dataipa/drivers/platform/msm"
    "qcom/opensource/datarmnet/core"
    "qcom/opensource/datarmnet-ext/aps"
    "qcom/opensource/datarmnet-ext/mem"
    "qcom/opensource/datarmnet-ext/offload"
    "qcom/opensource/datarmnet-ext/perf"
    "qcom/opensource/datarmnet-ext/perf_tether"
    "qcom/opensource/datarmnet-ext/sch"
    "qcom/opensource/datarmnet-ext/shs"
    "qcom/opensource/datarmnet-ext/wlan"
    "qcom/opensource/touch-drivers"
    "nxp/opensource/driver"
)

for mod in "${EXT_MODULES[@]}"; do
    if [ -d "$EXT_MODULES_ROOT/$mod" ]; then
        echo "Building external module: $mod..." | tee -a "$LOG_FILE"
        EXTRA_SYMS=$(find "$EXT_MODULES_ROOT" -name "Module.symvers" 2>/dev/null | tr '\n' ' ')
        kmake -C "$EXT_MODULES_ROOT/$mod" \
            M="$RPATH/$mod" \
            KERNEL_SRC="$KERNEL_SRC" \
            OUT_DIR="$KERNEL_SRC/out" \
            O="$KERNEL_SRC/out" \
            KERNEL_UAPI_HEADERS_DIR="$KERNEL_SRC/out" \
            KBUILD_EXTRA_SYMBOLS="$EXTRA_SYMS" \
            KBUILD_EXTRA="KBUILD_EXTRA_SYMBOLS=\"$EXTRA_SYMS\"" \
            2>&1 | tee -a "$LOG_FILE" || {
                echo "Warning: compilation of $mod failed, continuing..." | tee -a "$LOG_FILE"
                continue
            }

        kmake -C "$EXT_MODULES_ROOT/$mod" \
            M="$RPATH/$mod" \
            KERNEL_SRC="$KERNEL_SRC" \
            OUT_DIR="$KERNEL_SRC/out" \
            O="$KERNEL_SRC/out" \
            INSTALL_MOD_PATH="$MODULES_STAGING" \
            INSTALL_MOD_STRIP=1 \
            KERNEL_UAPI_HEADERS_DIR="$KERNEL_SRC/out" \
            KBUILD_EXTRA_SYMBOLS="$EXTRA_SYMS" \
            KBUILD_EXTRA="KBUILD_EXTRA_SYMBOLS=\"$EXTRA_SYMS\"" \
            modules_install 2>&1 | tee -a "$LOG_FILE" || {
                echo "Warning: modules_install of $mod failed, continuing..." | tee -a "$LOG_FILE"
                continue
            }
    fi
done

echo "Processing module stages and depmod..." | tee -a "$LOG_FILE"
KERNEL_RELEASE_VER=$(cat "$KERNEL_SRC/out/include/config/kernel.release" 2>/dev/null || echo "$KERNEL_VERSION")
depmod -b "$MODULES_STAGING" -F "$KERNEL_SRC/out/System.map" "$KERNEL_RELEASE_VER" 2>&1 | tee -a "$LOG_FILE" || true

MODULES_OUT=$(find "$MODULES_STAGING/lib/modules" -mindepth 1 -maxdepth 1 -type d | head -n1)
[ -z "$MODULES_OUT" ] && MODULES_OUT="$MODULES_STAGING/lib/modules/$KERNEL_RELEASE_VER"

VBOOT_DIR="$KERNEL_SRC/out/vendor_ramdisk"
VDLKM_DIR="$KERNEL_SRC/out/vendor_dlkm"
rm -rf "$VBOOT_DIR" "$VDLKM_DIR"
mkdir -p "$VBOOT_DIR" "$VDLKM_DIR"

FIRST_STAGE_MODULES=$(cat "$COMMON_DEVICE_DIR/modules.load.vendor_boot" 2>/dev/null || cat "$KERNEL_SRC/modules.list.msm.waipio" 2>/dev/null || echo "")
for mod in $FIRST_STAGE_MODULES; do
    mod_path=$(find "$MODULES_OUT" -name "$mod" -print -quit 2>/dev/null)
    [ -n "$mod_path" ] || continue
    cp "$mod_path" "$VBOOT_DIR/"
    echo "$mod" >> "$VBOOT_DIR/modules.load"
    echo "$mod" >> "$VBOOT_DIR/modules.load.recovery"
done

SECOND_STAGE_MODULES=$(cat "$COMMON_DEVICE_DIR/modules.load.recovery" 2>/dev/null || cat "$DEVICE_DIR/modules.list.second_stage" 2>/dev/null || echo "")
for mod in $SECOND_STAGE_MODULES; do
    mod_path=$(find "$MODULES_OUT" -name "$mod" -print -quit 2>/dev/null)
    [ -n "$mod_path" ] || continue
    cp "$mod_path" "$VBOOT_DIR/"
    cp "$mod_path" "$VDLKM_DIR/"
    echo "$mod" >> "$VBOOT_DIR/modules.load.recovery"
    echo "$mod" >> "$VDLKM_DIR/modules.load"
done

VENDOR_DLKM_MODULES=$(cat "$COMMON_DEVICE_DIR/modules.load" 2>/dev/null || cat "$DEVICE_DIR/modules.list.vendor_dlkm" 2>/dev/null || echo "")
for mod in $VENDOR_DLKM_MODULES; do
    mod_path=$(find "$MODULES_OUT" -name "$mod" -print -quit 2>/dev/null)
    [ -n "$mod_path" ] || continue
    cp "$mod_path" "$VDLKM_DIR/"
    echo "$mod" >> "$VDLKM_DIR/modules.load"
done

# Copy any remaining compiled modules to vendor_dlkm so no driver is missing
find "$MODULES_OUT" -type f -name "*.ko" -exec cp -n {} "$VDLKM_DIR/" \; 2>/dev/null || true

# Blocklists
[ -f "$COMMON_DEVICE_DIR/modules.blocklist" ] && cp "$COMMON_DEVICE_DIR/modules.blocklist" "$VDLKM_DIR/modules.blocklist"
[ -f "$COMMON_DEVICE_DIR/modules.blocklist.vendor_boot" ] && cp "$COMMON_DEVICE_DIR/modules.blocklist.vendor_boot" "$VBOOT_DIR/modules.blocklist"

# Copy module metadata
cp "$MODULES_OUT"/modules.{alias,dep,softdep} "$VDLKM_DIR/" 2>/dev/null || true
cp "$MODULES_OUT"/modules.{alias,dep,softdep} "$VBOOT_DIR/" 2>/dev/null || true

[ -f "$VDLKM_DIR/modules.dep" ] && sed -E -i 's|([^: ]*/)([^/]*\.ko)([:]?)([ ]|$)|/vendor_dlkm/lib/modules/\2\3\4|g' "$VDLKM_DIR/modules.dep"
[ -f "$VBOOT_DIR/modules.dep" ] && sed -E -i 's|([^: ]*/)([^/]*\.ko)([:]?)([ ]|$)|/lib/modules/\2\3\4|g' "$VBOOT_DIR/modules.dep"

echo "Packaging AnyKernel3..." | tee -a "$LOG_FILE"
rm -rf "$ROOT_DIR/AnyKernel3"
git clone https://gitlab.com/nekoshirro/AnyKernel3.git -b marble-evox "$ROOT_DIR/AnyKernel3" --depth 1 2>&1 | tee -a "$LOG_FILE" || die "clone AnyKernel3 failed"

cp "$BOOT_IMG_PATH" "$ROOT_DIR/AnyKernel3/Image" || die "copy Image failed"
cp "$BOOT_IMG_PATH" "$ROOT_DIR/AnyKernel3/kernel" || die "copy kernel failed"

# Packaging DTB for AnyKernel3
echo "Packaging DTB for AnyKernel3..." | tee -a "$LOG_FILE"
DTBS_BASE="$KERNEL_SRC/out/dtbs_base"
DTBS_OUT="$KERNEL_SRC/out/dtbs_out"
rm -rf "$DTBS_BASE" "$DTBS_OUT"
mkdir -p "$DTBS_BASE" "$DTBS_OUT"

cp "$KERNEL_SRC/out/arch/arm64/boot/dts/vendor/qcom"/*ukee*.dtb "$DTBS_BASE/" 2>/dev/null || true
cp "$KERNEL_SRC/out/arch/arm64/boot/dts/vendor/qcom"/*waipio*.dtb "$DTBS_BASE/" 2>/dev/null || true

if [ -f "$TOOLS_DIR/merge_dtbs.py" ]; then
    PATH="$TOOLS_DIR:$PATH" python3 "$TOOLS_DIR/merge_dtbs.py" \
        --base "$DTBS_BASE" \
        --techpack "$KERNEL_SRC/out/arch/arm64/boot/dts/vendor/qcom" \
        --out "$DTBS_OUT" 2>&1 | tee -a "$LOG_FILE" || true
fi

MERGED_MARBLE_DTB=$(find "$DTBS_OUT" -type f -name "*marble*.dtb" -print -quit 2>/dev/null || true)
if [ -z "$MERGED_MARBLE_DTB" ]; then
    MERGED_MARBLE_DTB=$(find "$KERNEL_SRC/out/arch/arm64/boot/dts/vendor/qcom" -type f -name "*marble*.dtb" -print -quit 2>/dev/null || true)
fi

if [ -n "$MERGED_MARBLE_DTB" ] && [ -f "$MERGED_MARBLE_DTB" ]; then
    echo "Using marble DTB: $MERGED_MARBLE_DTB" | tee -a "$LOG_FILE"
    cp "$MERGED_MARBLE_DTB" "$ROOT_DIR/AnyKernel3/dtb"
else
    echo "Concatenating available UKEE/WAIPIO DTBs for AnyKernel3/dtb..." | tee -a "$LOG_FILE"
    ALL_DTBS=$(find "$KERNEL_SRC/out/arch/arm64/boot/dts/vendor/qcom" -type f \( -name "*ukee*.dtb" -o -name "*waipio*.dtb" \) 2>/dev/null | sort -u)
    if [ -n "$ALL_DTBS" ]; then
        cat $ALL_DTBS > "$ROOT_DIR/AnyKernel3/dtb"
    fi
fi

# Copying compiled modules to AnyKernel3
echo "Copying compiled kernel modules to AnyKernel3..." | tee -a "$LOG_FILE"
mkdir -p "$ROOT_DIR/AnyKernel3/modules/vendor_dlkm"
cp -r "$VDLKM_DIR"/* "$ROOT_DIR/AnyKernel3/modules/vendor_dlkm/" 2>/dev/null || true

mkdir -p "$ROOT_DIR/AnyKernel3/modules/vendor_boot"
cp -r "$VBOOT_DIR"/* "$ROOT_DIR/AnyKernel3/modules/vendor_boot/" 2>/dev/null || true

mkdir -p "$ROOT_DIR/AnyKernel3/modules/system/lib/modules"
cp -r "$VDLKM_DIR"/*.ko "$ROOT_DIR/AnyKernel3/modules/system/lib/modules/" 2>/dev/null || true

[ -f "$ROOT_DIR/AnyKernel3/modules/vendor_dlkm/modules.load" ] && sort -u "$ROOT_DIR/AnyKernel3/modules/vendor_dlkm/modules.load" -o "$ROOT_DIR/AnyKernel3/modules/vendor_dlkm/modules.load"
cp "$ROOT_DIR/AnyKernel3/modules/vendor_dlkm/modules.load" "$ROOT_DIR/AnyKernel3/modules/modules.load" 2>/dev/null || true

TOTAL_MODULES=$(find "$ROOT_DIR/AnyKernel3/modules/vendor_dlkm" -type f -name "*.ko" | wc -l)
echo "Total modules packaged: $TOTAL_MODULES" | tee -a "$LOG_FILE"

# Adjust AnyKernel3 properties for Evolution-X
sed -i 's/kernel.string=.*/kernel.string=Evolution-X kernel/' "$ROOT_DIR/AnyKernel3/anykernel.sh"
if [ "$TOTAL_MODULES" -gt 0 ]; then
    sed -i 's/do.modules=0/do.modules=1/' "$ROOT_DIR/AnyKernel3/anykernel.sh"
else
    sed -i 's/do.modules=1/do.modules=0/' "$ROOT_DIR/AnyKernel3/anykernel.sh"
fi

FINAL_ZIP_NAME="Evo-12.x-${KERNEL_VERSION}.zip"
rm -f "$ROOT_DIR/$FINAL_ZIP_NAME"

echo "FINAL_ZIP_NAME=$FINAL_ZIP_NAME" | tee -a "$LOG_FILE"
(cd "$ROOT_DIR/AnyKernel3" && zip -r9 "$ROOT_DIR/$FINAL_ZIP_NAME" * -x .git README.md) 2>&1 | tee -a "$LOG_FILE" || die "AnyKernel3 zip creation failed"

DURATION=$(( $(date +%s) - BUILD_START_TIME ))
MD5_CHECK=$(md5sum "$ROOT_DIR/$FINAL_ZIP_NAME" | cut -d' ' -f1)
echo "MD5_CHECK=$MD5_CHECK" | tee -a "$LOG_FILE"

CAPTION="<b>✅ Build Finished!</b>

<b>Build took:</b> $((DURATION / 60)) minutes $((DURATION % 60)) seconds
<b>MD5:</b> <code>$MD5_CHECK</code>
<b>This kernel is based on Evolution-X kernel!</b>"

echo "Uploading kernel zip to Telegram..." | tee -a "$LOG_FILE"
if ! send_document "$TG_ADMIN_CHAT_ID" "$ROOT_DIR/$FINAL_ZIP_NAME" "$CAPTION"; then
    send_telegram "$TG_ADMIN_CHAT_ID" "<b>⚠️ Warning:</b> Kernel zip built successfully but Telegram upload failed: <code>$FINAL_ZIP_NAME</code>"
fi

echo "Build Succeeded: $FINAL_ZIP_NAME (MD5: $MD5_CHECK)"
