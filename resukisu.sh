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
export ROOT_VARIANT="ReSukiSU"
export COMPILER_NAME="🧪Alchemist LLVM clang version 22.1.4"
export TARGET_PRODUCT="lineage_marble"
export BUILD_VARIANT="user"
export TZ="Asia/Jakarta"
export BUILD_USERNAME="hafidz"
export BUILD_HOSTNAME="alchemist"

trap 'rm -f "$ROOT_DIR/monitor.py"' EXIT

MONITOR_PID=""
if wget -qO "$ROOT_DIR/monitor.py" "https://raw.githubusercontent.com/nekoshirro/platform_manifest-marble/refs/heads/kernel/monitor.py" && [ -s "$ROOT_DIR/monitor.py" ]; then
    python3 "$ROOT_DIR/monitor.py" --file "$LOG_FILE" --script "$0" &
    MONITOR_PID=$!
fi

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
    local resp
    [ -z "$TG_BOT_TOKEN" ] && return 0
    [ -z "$chat_id" ] && return 0
    [ ! -f "$file_path" ] && return 1
    resp=$(curl -s --max-time 300 \
        --form-string "chat_id=${chat_id}" \
        --form-string "caption=${caption}" \
        --form-string "parse_mode=HTML" \
        -F "document=@${file_path}" \
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
    echo "FATAL: $*" | tee -a "$LOG_FILE"
    echo "#### BUILD_EXIT_CODE=1 ####" | tee -a "$LOG_FILE"
    [ -n "$MONITOR_PID" ] && wait "$MONITOR_PID" 2>/dev/null
    if [ "$TRIGGER_SENT" -eq 1 ]; then
        local dur=$(( $(date +%s) - BUILD_START_TIME ))
        send_telegram "$TG_BUILD_CHAT_ID" "<b>❌ Build Failed</b>
<b>Root:</b> $ROOT_VARIANT
<b>Duration:</b> $((dur / 60)) minutes $((dur % 60)) seconds
<b>Reason:</b> <code>$*</code>"
    fi
    exit 1
}

if [ "${SKIP_SYNC:-0}" = "1" ] && [ -d "device/xiaomi/marble" ] && [ -f "prebuilts/clang/host/linux-x86/clang-alchemist/.lfs_ok" ]; then
    echo "Skipping repo sync and common tree clones (SKIP_SYNC=1)..." | tee -a "$LOG_FILE"
    rm -rf kernel/xiaomi/marble AnyKernel3 out/target/product/marble
    echo "Cloning kernel tree..." | tee -a "$LOG_FILE"
    git clone --recurse-submodules https://github.com/nekoshirro/platform_kernel_xiaomi_marble.git -b resukisu-staging kernel/xiaomi/marble --depth 1 2>&1 | tee -a "$LOG_FILE" || die "clone kernel tree failed"
else
    sudo apt-get install -y git git-lfs 2>&1 | tee -a "$LOG_FILE"
    git lfs install 2>&1 | tee -a "$LOG_FILE"

    echo "Re-initializing LineageOS manifest..." | tee -a "$LOG_FILE"
    repo init -u https://github.com/LineageOS/android.git -b lineage-23.2 --git-lfs --depth 1 2>&1 | tee -a "$LOG_FILE" || die "repo init failed"
    /opt/crave/resync.sh 2>&1 | tee -a "$LOG_FILE"
    repo sync -c -j"$(nproc --all)" --force-sync --force-remove-dirty --no-clone-bundle --no-tags 2>&1 | tee -a "$LOG_FILE" || die "repo sync failed"
    /opt/crave/resync.sh 2>&1 | tee -a "$LOG_FILE"

    echo "Cleaning workspace..." | tee -a "$LOG_FILE"
    rm -rf device/xiaomi/marble \
        vendor/xiaomi/marble \
        kernel/xiaomi/marble \
        kernel/xiaomi/marble-modules \
        kernel/xiaomi/marble-devicetrees \
        prebuilts/clang/host/linux-x86/clang-alchemist \
        AnyKernel3 \
        device/xiaomi/miuicamera-marble \
        vendor/xiaomi/miuicamera-marble \
        hardware/xiaomi \
        out/target/product/marble

    echo "Cloning device and kernel trees..." | tee -a "$LOG_FILE"
    git clone https://github.com/nekoshirro/platform_device_xiaomi_marble.git device/xiaomi/marble -b alchemist-llvm --depth 1 2>&1 | tee -a "$LOG_FILE" || die "clone device tree failed"
    git clone https://github.com/fiqri19102002/android_device_xiaomi_miuicamera-marble.git -b lineage-23.2 device/xiaomi/miuicamera-marble --depth 1 2>&1 | tee -a "$LOG_FILE" || die "clone miuicamera device failed"
    git clone https://github.com/nekoshirro/platform_vendor_xiaomi_marble.git -b 16 vendor/xiaomi/marble --depth 1 2>&1 | tee -a "$LOG_FILE" || die "clone vendor tree failed"
    git clone https://codeberg.org/fiqri19102002/proprietary_vendor_xiaomi_miuicamera-marble.git -b lineage-23.2 vendor/xiaomi/miuicamera-marble --depth 1 2>&1 | tee -a "$LOG_FILE" || die "clone miuicamera vendor failed"
    git clone --recurse-submodules https://github.com/nekoshirro/platform_kernel_xiaomi_marble.git -b resukisu-staging kernel/xiaomi/marble --depth 1 2>&1 | tee -a "$LOG_FILE" || die "clone kernel tree failed"
    git clone https://github.com/nekoshirro/platform_kernel_xiaomi_marble-devicetrees.git kernel/xiaomi/marble-devicetrees --depth 1 2>&1 | tee -a "$LOG_FILE" || die "clone kernel devicetrees failed"
    git clone https://github.com/nekoshirro/platform_kernel_xiaomi_marble-modules.git kernel/xiaomi/marble-modules --depth 1 2>&1 | tee -a "$LOG_FILE" || die "clone kernel modules failed"
    git clone https://github.com/LineageOS/android_hardware_xiaomi hardware/xiaomi -b lineage-23.2 --depth 1 2>&1 | tee -a "$LOG_FILE" || die "clone hardware xiaomi failed"

    echo "Cloning clang toolchain..." | tee -a "$LOG_FILE"
    git clone https://gitlab.com/nekoshirro/Alchemist-LLVM -b clang-22-LTO prebuilts/clang/host/linux-x86/clang-alchemist --depth 1 2>&1 | tee -a "$LOG_FILE" || die "clone Alchemist-LLVM failed"
    (git -C prebuilts/clang/host/linux-x86/clang-alchemist lfs install && git -C prebuilts/clang/host/linux-x86/clang-alchemist lfs pull) 2>&1 | tee -a "$LOG_FILE" || die "LFS pull Alchemist-LLVM failed"
    touch prebuilts/clang/host/linux-x86/clang-alchemist/.lfs_ok
fi

. build/envsetup.sh > >(tee -a "$LOG_FILE") 2>&1 || die "envsetup failed"
lunch lineage_marble-bp4a-user > >(tee -a "$LOG_FILE") 2>&1 || die "lunch failed"

KERNEL_VERSION=$(awk '
/^VERSION/ {v=$3}
/^PATCHLEVEL/ {p=$3}
/^SUBLEVEL/ {s=$3}
END {print v "." p "." s}
' kernel/xiaomi/marble/Makefile)
export KERNEL_VERSION
echo "KERNEL_VERSION=$KERNEL_VERSION" | tee -a "$LOG_FILE"

DOCKEROS=$(grep PRETTY_NAME /etc/os-release | cut -d '"' -f2)
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
echo "Starting Kernel Compilation..." | tee -a "$LOG_FILE"
make kernel bootimage -j"$(nproc --all)" 2>&1 | tee -a "$LOG_FILE"
BUILD_STATUS=${PIPESTATUS[0]}

if [ "$BUILD_STATUS" -eq 0 ]; then
    OBJ_PATH="out/target/product/marble/obj/KERNEL_OBJ/arch/arm64/boot"
    [ -f "$OBJ_PATH/Image" ] || die "Kernel Image not found at $OBJ_PATH/Image"

    echo "Packaging AnyKernel3..." | tee -a "$LOG_FILE"
    git clone https://gitlab.com/nekoshirro/AnyKernel3.git -b marble AnyKernel3 --depth 1 2>&1 | tee -a "$LOG_FILE" || die "clone AnyKernel3 failed"

    cp "$OBJ_PATH/Image" AnyKernel3/ || die "copy Image failed"
    cp "out/target/product/marble/kernel" AnyKernel3/ || die "copy kernel failed"

    DATE_TAG=$(date +%Y%m%d)
    TIME_TAG=$(date +%H%M)
    FINAL_ZIP_NAME="${KERNEL_NAME}-${DEVICE_CODE}-${KERNEL_VERSION}-${DATE_TAG}-${TIME_TAG}-ReSukiSU-signed.zip"
    rm -f "$ROOT_DIR/$FINAL_ZIP_NAME"

    echo "FINAL_ZIP_NAME=$FINAL_ZIP_NAME" | tee -a "$LOG_FILE"
    (cd AnyKernel3 && zip -r9 "$ROOT_DIR/$FINAL_ZIP_NAME" * -x .git README.md) 2>&1 | tee -a "$LOG_FILE" || die "AnyKernel3 zip creation failed"

    DURATION=$(( $(date +%s) - BUILD_START_TIME ))
    MD5_CHECK=$(md5sum "$ROOT_DIR/$FINAL_ZIP_NAME" | cut -d' ' -f1)
    echo "MD5_CHECK=$MD5_CHECK" | tee -a "$LOG_FILE"

    CAPTION="<b>✅ Build Finished!</b>

<b>Build took:</b> $((DURATION / 60)) minutes $((DURATION % 60)) seconds
<b>MD5:</b> <code>$MD5_CHECK</code>"

    echo "Uploading kernel zip to Telegram..." | tee -a "$LOG_FILE"
    if ! send_document "$TG_BUILD_CHAT_ID" "$ROOT_DIR/$FINAL_ZIP_NAME" "$CAPTION"; then
        send_telegram "$TG_ADMIN_CHAT_ID" "<b>⚠️ Warning:</b> Kernel zip built successfully but Telegram upload failed: <code>$FINAL_ZIP_NAME</code>"
    fi

    echo "#### BUILD_EXIT_CODE=0 ####" | tee -a "$LOG_FILE"
    [ -n "$MONITOR_PID" ] && wait "$MONITOR_PID" 2>/dev/null
else
    DURATION=$(( $(date +%s) - BUILD_START_TIME ))
    echo "#### BUILD_EXIT_CODE=$BUILD_STATUS ####" | tee -a "$LOG_FILE"
    [ -n "$MONITOR_PID" ] && wait "$MONITOR_PID" 2>/dev/null

    FAIL_MSG="<b>❌ Build Failed</b>
<b>Root:</b> $ROOT_VARIANT
<b>Duration:</b> $((DURATION / 60)) minutes $((DURATION % 60)) seconds"
    send_telegram "$TG_BUILD_CHAT_ID" "$FAIL_MSG"
fi

exit "$BUILD_STATUS"
