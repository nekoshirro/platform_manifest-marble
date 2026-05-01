#!/bin/bash

if [ -f "$HOME/.secrets" ]; then
    source "$HOME/.secrets"
else
    echo "File .secrets not found in $HOME"
fi

if [ -f "$(pwd)/.secrets" ]; then
    source "$(pwd)/.secrets"
else
    echo "File .secrets not found in $(pwd)"
fi

# =========================================================
# GLOBAL CONFIGURATION & TIMER
# =========================================================

DEVICE_CODE="marble"
DEVICE_NAME="Redmi Note 12 Turbo"
KERNEL_NAME="Alchemist"

# SHELL CONFIGURATION
export TZ="Asia/Jakarta"
export BUILD_USERNAME=hafidz
export BUILD_HOSTNAME=alchemist

# =========================================================
# TELEGRAM FUNCTIONS
# =========================================================

send_telegram() {
  local chat_id="$1"
  local message="$2"

  local _TK="$TG_BOT_TOKEN"

  curl -s -X POST "https://api.telegram.org/bot${_TK}/sendMessage" \
    -d "chat_id=${chat_id}" \
    -d "text=${message}" \
    -d "parse_mode=HTML" \
    -d "disable_web_page_preview=true" \
    > /dev/null
}

send_document() {
  local chat_id="$1"
  local file_path="$2"
  local caption="$3"

  local _TK="$TG_BOT_TOKEN"

  curl -s -F chat_id="${chat_id}" \
       -F document=@"${file_path}" \
       -F caption="${caption}" \
       -F parse_mode="HTML" \
       "https://api.telegram.org/bot${_TK}/sendDocument" \
       > /dev/null
}

COMPILER_NAME="🧪Alchemist LLVM clang version 22.1.4"

# =========================================================
# GIT LFS
# =========================================================
sudo apt-get install -y git git-lfs
git lfs install

# =========================================================
# PRE-BUILD SETUP
# =========================================================

echo "Re-init LineageOS Setup..."
repo init -u https://github.com/LineageOS/android.git -b lineage-23.2 --git-lfs
/opt/crave/resync.sh
repo sync -c -j$(nproc --all) --force-sync --no-clone-bundle --no-tags
/opt/crave/resync.sh
repo sync -c -j$(nproc --all) --force-sync --no-clone-bundle --no-tags
/opt/crave/resync.sh

echo "Cleaning workspace..."
rm -rf device/xiaomi/marble
rm -rf vendor/xiaomi/marble
rm -rf kernel/xiaomi/marble
rm -rf kernel/xiaomi/marble-modules
rm -rf kernel/xiaomi/marble-devicetrees
rm -rf prebuilts/clang/host/linux-x86/clang-alchemist
rm -rf AnyKernel3
rm -rf device/xiaomi/miuicamera-marble
rm -rf vendor/xiaomi/miuicamera-marble
rm -rf hardware/xiaomi
rm -rf out/target/product/marble

# =========================================================
# CLONING SOURCES
# =========================================================

echo "Cloning device stuff..."
# Device Trees
git clone https://github.com/nekoshirro/platform_device_xiaomi_marble.git device/xiaomi/marble -b alchemist-llvm --depth 1
git clone https://github.com/fiqri19102002/android_device_xiaomi_miuicamera-marble.git -b lineage-23.2 device/xiaomi/miuicamera-marble
git clone https://github.com/nekoshirro/platform_vendor_xiaomi_marble.git -b 16 vendor/xiaomi/marble --depth 1
git clone https://codeberg.org/fiqri19102002/proprietary_vendor_xiaomi_miuicamera-marble.git -b lineage-23.2 vendor/xiaomi/miuicamera-marble
git clone --recurse-submodules https://github.com/nekoshirro/platform_kernel_xiaomi_marble.git -b resukisu-staging kernel/xiaomi/marble --depth 1
git clone https://github.com/nekoshirro/platform_kernel_xiaomi_marble-devicetrees.git kernel/xiaomi/marble-devicetrees --depth 1
git clone https://github.com/nekoshirro/platform_kernel_xiaomi_marble-modules.git kernel/xiaomi/marble-modules --depth 1
git clone https://github.com/LineageOS/android_hardware_xiaomi hardware/xiaomi -b lineage-23.2 --depth 1

echo "Cloning clang..."
git clone https://gitlab.com/nekoshirro/Alchemist-LLVM -b clang-22-LTO prebuilts/clang/host/linux-x86/clang-alchemist
pushd prebuilts/clang/host/linux-x86/clang-alchemist
git lfs install
git lfs pull
git lfs fetch --all
popd

# =========================================================
# PREPARE BUILD ENV
# =========================================================

. build/envsetup.sh
lunch lineage_marble-bp4a-user

# =========================================================
# GET KERNEL VERSION (SAFE METHOD)
# =========================================================

KERNEL_VERSION=$(awk '
/^VERSION/ {v=$3}
/^PATCHLEVEL/ {p=$3}
/^SUBLEVEL/ {s=$3}
END {print v "." p "." s}
' kernel/xiaomi/marble/Makefile)

# =========================================================
# BUILD INFO
# =========================================================

DOCKEROS=$(grep PRETTY_NAME /etc/os-release | cut -d '"' -f2)
DATE_EN=$(TZ="Asia/Jakarta" date +'%d %B %Y, %H:%M WIB')

START_MSG="
<b>🔨Kernel Build Triggered</b>

<b>Docker OS:</b> $DOCKEROS
<b>Date:</b> $DATE_EN
<b>Device:</b> $DEVICE_NAME
<b>Codename:</b> $DEVICE_CODE
<b>Kernel Version:</b> $KERNEL_VERSION
<b>Root:</b> ReSukiSU
<b>Compiler:</b> $COMPILER_NAME
"

send_telegram "$TG_BUILD_CHAT_ID" "$START_MSG"

# =========================================================
# COMPILATION
# =========================================================

BUILD_START_TIME=$(date +%s)

make kernel bootimage -j$(nproc --all)
BUILD_STATUS=$?

# =========================================================
# POST BUILD
# =========================================================

if [[ $BUILD_STATUS -eq 0 ]]; then

    OBJ_PATH="out/target/product/marble/obj/KERNEL_OBJ/arch/arm64/boot"

    # KPM Patch
    pushd $OBJ_PATH
    wget https://github.com/SukiSU-Ultra/SukiSU_KernelPatch_patch/releases/download/0.13.0/patch_linux
    chmod +x patch_linux
    ./patch_linux Image
    rm -rf Image
    mv oImage Image
    popd

    git clone https://gitlab.com/nekoshirro/AnyKernel3.git -b marble AnyKernel3

    cp "$OBJ_PATH/Image" AnyKernel3/
    cp "out/target/product/marble/kernel" AnyKernel3/

    DATE_TAG=$(date +%Y%m%d)
    TIME_TAG=$(date +%H%M)

    FINAL_ZIP_NAME="${KERNEL_NAME}-${DEVICE_CODE}-${KERNEL_VERSION}-${DATE_TAG}-${TIME_TAG}-ReSukiSU-signed.zip"

    cd AnyKernel3
    zip -r9 "../$FINAL_ZIP_NAME" * -x .git README.md
    cd ..

    DURATION=$(( $(date +%s) - BUILD_START_TIME ))
    MD5_CHECK=$(md5sum "$FINAL_ZIP_NAME" | cut -d' ' -f1)

    CAPTION="
<b>✅ Build Finished!</b>

<b>Build took:</b> $((DURATION / 60)) minutes $((DURATION % 60)) seconds
<b>MD5:</b> <code>$MD5_CHECK</code>
"
    send_document "$TG_BUILD_CHAT_ID" "$FINAL_ZIP_NAME" "$CAPTION"
else
    DURATION=$(( $(date +%s) - BUILD_START_TIME ))
    FAIL_MSG="
<b>❌ Build Failed</b>
<b>Duration:</b> $((DURATION / 60)) minutes $((DURATION % 60)) seconds
"
    send_telegram "$TG_BUILD_CHAT_ID" "$FAIL_MSG"

    if [ -f "out/error.log" ]; then
        send_document "$TG_BUILD_CHAT_ID" "out/error.log" "<b>Build Error Log</b>"
    fi

fi
