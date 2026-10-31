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
export KERNEL_NAME="[Re]Shinomiya"
export ROOT_VARIANT="KernelSU-Next"
export CLANG_MAJOR="${CLANG_MAJOR:-23}"
export COMPILER_NAME="🧪Alchemist LLVM Clang ${CLANG_MAJOR}"
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
<b>Duration:</b> $((dur / 60)) minutes $((dur % 60)) seconds"
        if [ -f "$LOG_FILE" ] && [ -s "$LOG_FILE" ]; then
            send_document "$TG_BUILD_CHAT_ID" "$LOG_FILE" "$fail_msg" || send_telegram "$TG_BUILD_CHAT_ID" "$fail_msg"
        else
            send_telegram "$TG_BUILD_CHAT_ID" "$fail_msg"
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
REQUIRED_PKGS="bc bison build-essential curl device-tree-compiler flex git git-lfs kmod libelf-dev libssl-dev python3 zip"
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
    curl -fsSL "https://raw.githubusercontent.com/LineageOS/android_vendor_lineage/lineage-22.1/build/tools/merge_dtbs.py" -o "$TOOLS_DIR/merge_dtbs.py" || die "failed to download merge_dtbs.py"
    chmod +x "$TOOLS_DIR/merge_dtbs.py"
fi

if [ ! -f "$TOOLS_DIR/ufdt_apply_overlay" ] || [ ! -x "$TOOLS_DIR/ufdt_apply_overlay" ]; then
    echo "Downloading ufdt_apply_overlay..." | tee -a "$LOG_FILE"
    curl -fsSL "https://raw.githubusercontent.com/papel-palyground/android_kernel_prebuilts_build-tools/lineage-23.2/linux-x86/bin/ufdt_apply_overlay" -o "$TOOLS_DIR/ufdt_apply_overlay" || die "failed to download ufdt_apply_overlay"
    chmod +x "$TOOLS_DIR/ufdt_apply_overlay"
fi

if [ ! -f "$TOOLS_DIR/fdtoverlaymerge" ] || [ ! -x "$TOOLS_DIR/fdtoverlaymerge" ]; then
    echo "Downloading fdtoverlaymerge..." | tee -a "$LOG_FILE"
    curl -fsSL "https://raw.githubusercontent.com/papel-palyground/android_kernel_prebuilts_build-tools/lineage-23.2/linux-x86/bin/fdtoverlaymerge" -o "$TOOLS_DIR/fdtoverlaymerge" || die "failed to download fdtoverlaymerge"
    chmod +x "$TOOLS_DIR/fdtoverlaymerge"
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

CLANG_DIR="$ROOT_DIR/toolchain/Alchemist-LLVM"
mkdir -p "$ROOT_DIR/toolchain"

echo "Checking latest Alchemist LLVM (Clang $CLANG_MAJOR) release from GitHub..." | tee -a "$LOG_FILE"
LATEST_RELEASE_JSON=$(curl -sL --max-time 15 "https://api.github.com/repos/nekoshirro/Alchemist-LLVM/releases/latest" 2>/dev/null || true)
CLANG_URL=$(echo "$LATEST_RELEASE_JSON" | jq -r ".assets[] | select((.name | startswith(\"Alchemist-LLVM-${CLANG_MAJOR}-\")) and (.name | endswith(\".tar.xz\"))) | .browser_download_url" 2>/dev/null | head -n1)
if [ -z "$CLANG_URL" ] || [ "$CLANG_URL" = "null" ]; then
    CLANG_URL=$(echo "$LATEST_RELEASE_JSON" | grep "browser_download_url" | grep "Alchemist-LLVM-${CLANG_MAJOR}-" | grep -o 'https://[^"]*' | head -n1)
fi

# Fallback to known release URL if GitHub API query fails
if [ -z "$CLANG_URL" ] || [ "$CLANG_URL" = "null" ]; then
    CLANG_URL="https://github.com/nekoshirro/Alchemist-LLVM/releases/download/lto-20261030/Alchemist-LLVM-${CLANG_MAJOR}-20261030.tar.xz"
fi

ASSET_NAME=$(basename "$CLANG_URL")

if [ ! -x "$CLANG_DIR/bin/clang" ] || [ ! -f "$CLANG_DIR/.asset_tag" ] || [ "$(cat "$CLANG_DIR/.asset_tag" 2>/dev/null)" != "$ASSET_NAME" ]; then
    echo "Downloading latest Alchemist-LLVM ($ASSET_NAME)..." | tee -a "$LOG_FILE"
    rm -rf "$CLANG_DIR"
    mkdir -p "$CLANG_DIR"
    ARCHIVE_PATH="$ROOT_DIR/toolchain/$ASSET_NAME"
    if ! curl -fSL --retry 3 --connect-timeout 30 "$CLANG_URL" -o "$ARCHIVE_PATH"; then
        wget -qO "$ARCHIVE_PATH" "$CLANG_URL" || die "failed to download $ASSET_NAME"
    fi
    echo "Extracting $ASSET_NAME..." | tee -a "$LOG_FILE"
    tar -xf "$ARCHIVE_PATH" -C "$CLANG_DIR" 2>&1 | tee -a "$LOG_FILE" || die "failed to extract $ASSET_NAME"
    rm -f "$ARCHIVE_PATH"
    echo "$ASSET_NAME" > "$CLANG_DIR/.asset_tag"
    echo "Alchemist-LLVM $ASSET_NAME extracted successfully." | tee -a "$LOG_FILE"
else
    echo "Using existing Alchemist-LLVM toolchain ($ASSET_NAME) in $CLANG_DIR..." | tee -a "$LOG_FILE"
fi

export PATH="$CLANG_DIR/bin:$PATH"
which clang >/dev/null 2>&1 || die "clang binary not found in $CLANG_DIR/bin"

# Dynamically resolve exact compiler version for Telegram & logs
RAW_CLANG_VER=$("$CLANG_DIR/bin/clang" --version 2>/dev/null | head -n1 | sed -e 's/  */ /g' -e 's/[<>]//g')
if echo "$RAW_CLANG_VER" | grep -qi "Alchemist"; then
    export COMPILER_NAME="$RAW_CLANG_VER"
else
    export COMPILER_NAME="🧪Alchemist LLVM $RAW_CLANG_VER"
fi
echo "Compiler: $COMPILER_NAME" | tee -a "$LOG_FILE"

DEVICE_DIR="$ROOT_DIR/device/xiaomi/marble"
sync_git_repo "$DEVICE_DIR" "https://github.com/nekoshirro/platform_device_xiaomi_marble.git" "alchemist-llvm" "0"

KERNEL_SRC="$ROOT_DIR/kernel/xiaomi/marble"
sync_git_repo "$KERNEL_SRC" "https://github.com/nekoshirro/platform_kernel_xiaomi_marble.git" "ksu-next-staging" "1"

echo "Applying KernelSU-Next manager.patch..." | tee -a "$LOG_FILE"
curl -fsSL "https://raw.githubusercontent.com/nekoshirro/platform_manifest-marble/refs/heads/kernel/manager.patch" -o /tmp/manager.patch || die "Download manager.patch failed"
patch -d "$KERNEL_SRC/KernelSU-Next" -p1 < /tmp/manager.patch 2>&1 | tee -a "$LOG_FILE" || die "Apply manager.patch failed"
rm -f /tmp/manager.patch

DT_SRC="$ROOT_DIR/kernel/xiaomi/marble-devicetrees"
sync_git_repo "$DT_SRC" "https://github.com/nekoshirro/platform_kernel_xiaomi_marble-devicetrees.git" "16" "0"

EXT_MODULES_ROOT="$ROOT_DIR/kernel/xiaomi/marble-modules"
sync_git_repo "$EXT_MODULES_ROOT" "https://github.com/nekoshirro/platform_kernel_xiaomi_marble-modules.git" "16" "0"

mkdir -p "$KERNEL_SRC/arch/arm64/boot/dts"
rm -f "$KERNEL_SRC/arch/arm64/boot/dts/vendor"
ln -s "$DT_SRC" "$KERNEL_SRC/arch/arm64/boot/dts/vendor"

ln -sfn "$EXT_MODULES_ROOT" "$KERNEL_SRC/marble-modules"
mkdir -p "$KERNEL_SRC/out"
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
<b>Compiler:</b> $COMPILER_NAME"

send_telegram "$TG_BUILD_CHAT_ID" "$START_MSG"
TRIGGER_SENT=1

BUILD_START_TIME=$(date +%s)
echo "Generating kernel configuration from BoardConfig.mk..." | tee -a "$LOG_FILE"
mkdir -p out

CONFIG_LIST=$(sed -n '/TARGET_KERNEL_CONFIG :=/,/[^\\]$/p' "$DEVICE_DIR/BoardConfig.mk" | grep -v 'TARGET_KERNEL_CONFIG' | tr -d '\\' | xargs)
[ -z "$CONFIG_LIST" ] && CONFIG_LIST="gki_defconfig vendor/waipio_GKI.config vendor/marble_GKI.config vendor/debugfs.config vendor/extra.config"

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

# echo "Compiling Device Tree Blobs (DTBs)..." | tee -a "$LOG_FILE"
# kmake dtbs 2>&1 | tee -a "$LOG_FILE" || die "DTB compilation failed"

# echo "Merging DTBs using merge_dtbs.py..." | tee -a "$LOG_FILE"
# DTBS_BASE="$KERNEL_SRC/out/dtbs_base"
# DTBS_OUT="$KERNEL_SRC/out/dtbs_out"
# rm -rf "$DTBS_BASE" "$DTBS_OUT"
# mkdir -p "$DTBS_BASE" "$DTBS_OUT"

# mv "$KERNEL_SRC/out/arch/arm64/boot/dts/vendor/qcom"/*ukee*.dtb "$DTBS_BASE/" 2>/dev/null || true
# mv "$KERNEL_SRC/out/arch/arm64/boot/dts/vendor/qcom"/*waipio*.dtb "$DTBS_BASE/" 2>/dev/null || true

# find "$KERNEL_SRC/out/arch/arm64/boot/dts/vendor/qcom" -maxdepth 1 -name "*.dtbo" ! -name "*marble*" -delete 2>/dev/null || true

# if PATH="$TOOLS_DIR:$PATH" python3 "$TOOLS_DIR/merge_dtbs.py" --base "$DTBS_BASE" --techpack "$KERNEL_SRC/out/arch/arm64/boot/dts/vendor/qcom" --out "$DTBS_OUT" 2>&1 | tee -a "$LOG_FILE"; then
#     echo "merge_dtbs completed successfully." | tee -a "$LOG_FILE"
# else
#     echo "WARNING: merge_dtbs encountered an issue, will fallback to base DTBs." | tee -a "$LOG_FILE"
#     rm -rf "$DTBS_OUT"/*
# fi

# echo "Compiling in-tree Kernel Modules..." | tee -a "$LOG_FILE"
# MODULES_STAGING="$KERNEL_SRC/out/modules_staging"
# rm -rf "$MODULES_STAGING"
# mkdir -p "$MODULES_STAGING"

# kmake modules 2>&1 | tee -a "$LOG_FILE" || die "in-tree modules compilation failed"
# kmake INSTALL_MOD_PATH="$MODULES_STAGING" INSTALL_MOD_STRIP=1 modules_install 2>&1 | tee -a "$LOG_FILE" || die "in-tree modules install failed"

# echo "Compiling external Kernel Modules..." | tee -a "$LOG_FILE"
# find "$EXT_MODULES_ROOT" -name "Module.symvers" -delete 2>/dev/null || true
# RPATH=$(python3 -c 'import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "$EXT_MODULES_ROOT" "$KERNEL_SRC")

# EXT_MODULES=(
#     "qcom/opensource/mmrm-driver"
#     "qcom/opensource/audio-kernel"
#     "qcom/opensource/camera-kernel"
#     "qcom/opensource/cvp-kernel"
#     "qcom/opensource/dataipa/drivers/platform/msm"
#     "qcom/opensource/datarmnet/core"
#     "qcom/opensource/datarmnet-ext/aps"
#     "qcom/opensource/datarmnet-ext/offload"
#     "qcom/opensource/datarmnet-ext/shs"
#     "qcom/opensource/datarmnet-ext/perf"
#     "qcom/opensource/datarmnet-ext/perf_tether"
#     "qcom/opensource/datarmnet-ext/sch"
#     "qcom/opensource/datarmnet-ext/wlan"
#     "qcom/opensource/display-drivers/msm"
#     "qcom/opensource/eva-kernel"
#     "qcom/opensource/video-driver"
#     "qcom/opensource/wlan/qcacld-3.0/.qca6490"
# )

# for mod in "${EXT_MODULES[@]}"; do
#     if [ -d "$EXT_MODULES_ROOT/$mod" ]; then
#         echo "Building external module: $mod..." | tee -a "$LOG_FILE"
#         EXTRA_SYMS=$(find "$EXT_MODULES_ROOT" -name "Module.symvers" 2>/dev/null | tr '\n' ' ')
#         kmake -C "$EXT_MODULES_ROOT/$mod" \
#             M="$RPATH/$mod" \
#             KERNEL_SRC="$KERNEL_SRC" \
#             OUT_DIR="$KERNEL_SRC/out" \
#             O="$KERNEL_SRC/out" \
#             KERNEL_UAPI_HEADERS_DIR="$KERNEL_SRC/out" \
#             KBUILD_EXTRA_SYMBOLS="$EXTRA_SYMS" \
#             KBUILD_EXTRA="KBUILD_EXTRA_SYMBOLS=\"$EXTRA_SYMS\"" \
#             2>&1 | tee -a "$LOG_FILE" || die "failed compiling external module $mod"

#         kmake -C "$EXT_MODULES_ROOT/$mod" \
#             M="$RPATH/$mod" \
#             KERNEL_SRC="$KERNEL_SRC" \
#             OUT_DIR="$KERNEL_SRC/out" \
#             O="$KERNEL_SRC/out" \
#             INSTALL_MOD_PATH="$MODULES_STAGING" \
#             INSTALL_MOD_STRIP=1 \
#             KERNEL_UAPI_HEADERS_DIR="$KERNEL_SRC/out" \
#             KBUILD_EXTRA_SYMBOLS="$EXTRA_SYMS" \
#             KBUILD_EXTRA="KBUILD_EXTRA_SYMBOLS=\"$EXTRA_SYMS\"" \
#             modules_install 2>&1 | tee -a "$LOG_FILE" || die "failed installing external module $mod"
#     fi
# done

# echo "Processing module stages and depmod..." | tee -a "$LOG_FILE"
# KERNEL_RELEASE_VER=$(cat "$KERNEL_SRC/out/include/config/kernel.release" 2>/dev/null || echo "$KERNEL_VERSION")
# depmod -b "$MODULES_STAGING" -F "$KERNEL_SRC/out/System.map" "$KERNEL_RELEASE_VER" 2>&1 | tee -a "$LOG_FILE" || true

# MODULES_OUT=$(find "$MODULES_STAGING/lib/modules" -mindepth 1 -maxdepth 1 -type d | head -n1)
# [ -z "$MODULES_OUT" ] && MODULES_OUT="$MODULES_STAGING/lib/modules/$KERNEL_RELEASE_VER"

# VBOOT_DIR="$KERNEL_SRC/out/vendor_ramdisk"
# VDLKM_DIR="$KERNEL_SRC/out/vendor_dlkm"
# rm -rf "$VBOOT_DIR" "$VDLKM_DIR"
# mkdir -p "$VBOOT_DIR" "$VDLKM_DIR"

# FIRST_STAGE_MODULES=$(cat "$KERNEL_SRC/modules.list.msm.waipio" 2>/dev/null || echo "")
# for mod in $FIRST_STAGE_MODULES; do
#     mod_path=$(find "$MODULES_OUT" -name "$mod" -print -quit 2>/dev/null)
#     [ -n "$mod_path" ] || continue
#     cp "$mod_path" "$VBOOT_DIR/"
#     echo "$mod" >> "$VBOOT_DIR/modules.load"
#     echo "$mod" >> "$VBOOT_DIR/modules.load.recovery"
# done

# SECOND_STAGE_MODULES=$(cat "$DEVICE_DIR/modules.list.second_stage" 2>/dev/null || echo "")
# for mod in $SECOND_STAGE_MODULES; do
#     mod_path=$(find "$MODULES_OUT" -name "$mod" -print -quit 2>/dev/null)
#     [ -n "$mod_path" ] || continue
#     cp "$mod_path" "$VBOOT_DIR/"
#     cp "$mod_path" "$VDLKM_DIR/"
#     echo "$mod" >> "$VBOOT_DIR/modules.load.recovery"
#     echo "$mod" >> "$VDLKM_DIR/modules.load"
# done

# VENDOR_DLKM_MODULES=$(cat "$DEVICE_DIR/modules.list.vendor_dlkm" 2>/dev/null || echo "")
# for mod in $VENDOR_DLKM_MODULES; do
#     mod_path=$(find "$MODULES_OUT" -name "$mod" -print -quit 2>/dev/null)
#     [ -n "$mod_path" ] || continue
#     cp "$mod_path" "$VDLKM_DIR/"
#     echo "$mod" >> "$VDLKM_DIR/modules.load"
# done

# find "$MODULES_OUT" -type f -name "*.ko" -exec cp -n {} "$VDLKM_DIR/" \; 2>/dev/null || true

# [ -f "$KERNEL_SRC/modules.vendor_blocklist.msm.waipio" ] && cp "$KERNEL_SRC/modules.vendor_blocklist.msm.waipio" "$VDLKM_DIR/modules.blocklist"
# [ -f "$KERNEL_SRC/modules.vendor_blocklist.msm.waipio" ] && cp "$KERNEL_SRC/modules.vendor_blocklist.msm.waipio" "$VBOOT_DIR/modules.blocklist"

# cp "$MODULES_OUT"/modules.{alias,dep,softdep} "$VDLKM_DIR/" 2>/dev/null || true
# cp "$MODULES_OUT"/modules.{alias,dep,softdep} "$VBOOT_DIR/" 2>/dev/null || true

# [ -f "$VDLKM_DIR/modules.dep" ] && sed -E -i 's|([^: ]*/)([^/]*\.ko)([:]?)([ ]|$)|/vendor_dlkm/lib/modules/\2\3\4|g' "$VDLKM_DIR/modules.dep"
# [ -f "$VBOOT_DIR/modules.dep" ] && sed -E -i 's|([^: ]*/)([^/]*\.ko)([:]?)([ ]|$)|/lib/modules/\2\3\4|g' "$VBOOT_DIR/modules.dep"

BOOT_IMG_PATH="$KERNEL_SRC/out/arch/arm64/boot/Image"
[ -f "$BOOT_IMG_PATH" ] || die "Kernel Image not found at $BOOT_IMG_PATH"

echo "Packaging AnyKernel3..." | tee -a "$LOG_FILE"
rm -rf "$ROOT_DIR/AnyKernel3"
git clone https://gitlab.com/nekoshirro/AnyKernel3.git -b marble "$ROOT_DIR/AnyKernel3" --depth 1 2>&1 | tee -a "$LOG_FILE" || die "clone AnyKernel3 failed"

cp "$BOOT_IMG_PATH" "$ROOT_DIR/AnyKernel3/Image" || die "copy Image failed"
cp "$BOOT_IMG_PATH" "$ROOT_DIR/AnyKernel3/kernel" || die "copy kernel failed"

# Packaging DTB for AnyKernel3...
# MERGED_DTB_FILES=$(find "$DTBS_OUT" -type f -name "*.dtb" 2>/dev/null | sort)
# if [ -n "$MERGED_DTB_FILES" ]; then
#     echo "Concatenating merged DTBs into AnyKernel3/dtb..." | tee -a "$LOG_FILE"
#     cat $MERGED_DTB_FILES > "$ROOT_DIR/AnyKernel3/dtb"
# else
#     echo "Falling back to compiled DTBs for AnyKernel3/dtb..." | tee -a "$LOG_FILE"
#     FALLBACK_DTBS=$(find "$DTBS_BASE" "$KERNEL_SRC/out/arch/arm64/boot/dts" -type f -name "*.dtb" 2>/dev/null | sort -u)
#     if [ -n "$FALLBACK_DTBS" ]; then
#         cat $FALLBACK_DTBS > "$ROOT_DIR/AnyKernel3/dtb"
#     fi
# fi

# echo "Copying compiled kernel modules to AnyKernel3..." | tee -a "$LOG_FILE"
# mkdir -p "$ROOT_DIR/AnyKernel3/modules/vendor_dlkm"
# cp -r "$VDLKM_DIR"/* "$ROOT_DIR/AnyKernel3/modules/vendor_dlkm/" 2>/dev/null || true

# mkdir -p "$ROOT_DIR/AnyKernel3/modules/vendor_boot"
# cp -r "$VBOOT_DIR"/* "$ROOT_DIR/AnyKernel3/modules/vendor_boot/" 2>/dev/null || true

# mkdir -p "$ROOT_DIR/AnyKernel3/modules/system/lib/modules"
# cp -r "$VDLKM_DIR"/*.ko "$ROOT_DIR/AnyKernel3/modules/system/lib/modules/" 2>/dev/null || true

# [ -f "$ROOT_DIR/AnyKernel3/modules/vendor_dlkm/modules.load" ] && sort -u "$ROOT_DIR/AnyKernel3/modules/vendor_dlkm/modules.load" -o "$ROOT_DIR/AnyKernel3/modules/vendor_dlkm/modules.load"
# cp "$ROOT_DIR/AnyKernel3/modules/vendor_dlkm/modules.load" "$ROOT_DIR/AnyKernel3/modules/modules.load" 2>/dev/null || true

# TOTAL_MODULES=$(find "$ROOT_DIR/AnyKernel3/modules/vendor_dlkm" -type f -name "*.ko" | wc -l)
# echo "Total modules packaged: $TOTAL_MODULES" | tee -a "$LOG_FILE"

# if [ "$TOTAL_MODULES" -gt 0 ]; then
#     sed -i 's/do.modules=0/do.modules=1/' "$ROOT_DIR/AnyKernel3/anykernel.sh"
# fi

DATE_TAG=$(date +%Y%m%d)
TIME_TAG=$(date +%H%M)
FINAL_ZIP_NAME="${KERNEL_NAME}-${DEVICE_CODE}-${KERNEL_VERSION}-${DATE_TAG}-${TIME_TAG}-KSUN.zip"
rm -f "$ROOT_DIR/$FINAL_ZIP_NAME"

(cd "$ROOT_DIR/AnyKernel3" && zip -r9 "$ROOT_DIR/$FINAL_ZIP_NAME" * -x .git README.md) 2>&1 | tee -a "$LOG_FILE" || die "AnyKernel3 zip creation failed"

DURATION=$(( $(date +%s) - BUILD_START_TIME ))
MD5_CHECK=$(md5sum "$ROOT_DIR/$FINAL_ZIP_NAME" | cut -d' ' -f1)

CAPTION="<b>✅ Build Finished!</b>

<b>Build took:</b> $((DURATION / 60)) minutes $((DURATION % 60)) seconds
<b>MD5:</b> <code>$MD5_CHECK</code>"

echo "Uploading kernel zip to Telegram..." | tee -a "$LOG_FILE"
if ! send_document "$TG_BUILD_CHAT_ID" "$ROOT_DIR/$FINAL_ZIP_NAME" "$CAPTION"; then
    send_telegram "$TG_BUILD_CHAT_ID" "<b>⚠️ Warning:</b> Kernel zip built successfully but Telegram upload failed: <code>$FINAL_ZIP_NAME</code>"
fi

if [ -f "$LOG_FILE" ]; then
    echo "Uploading log.txt to Telegram..." | tee -a "$LOG_FILE"
    send_document "$TG_BUILD_CHAT_ID" "$LOG_FILE" "<b>📄 Build Log (Success)</b>" || true
fi

echo "Build Succeeded: $FINAL_ZIP_NAME (MD5: $MD5_CHECK)"
