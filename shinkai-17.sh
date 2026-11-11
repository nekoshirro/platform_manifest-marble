#!/bin/bash
set -o pipefail

for sec in "/tmp/src/android/.secrets" "$HOME/.secrets" "$PWD/.secrets"; do
    [ -f "$sec" ] && source "$sec"
done

: > log.txt

export DEVICE_CODE="marble"
export DEVICE_DISPLAY="Redmi Note 12 Turbo"
export ROM_NAME="Shinkai Project"
export ANDROID_VERSION="17"
export BUILD_TARGET="Shinkai Project"
export TARGET_PRODUCT="shinkai_marble"
export BUILD_VARIANT="user"
export BUILD_USERNAME="hafidz"
export BUILD_HOSTNAME="alchemist"
export TZ="Asia/Jakarta"

PUBLIC_CHAT_ID="${TG_BUILD_CHAT_ID:-}"

MONITOR_PID=""
if [ ! -s monitor.py ]; then
    wget -qO monitor.py "https://raw.githubusercontent.com/nekoshirro/platform_manifest-marble/refs/heads/shinkai-17/monitor.py"
fi
if [ -s monitor.py ]; then
    python3 monitor.py --file log.txt &
    MONITOR_PID=$!
fi

send_public_telegram() {
    [ -z "$TG_BOT_TOKEN" ] && return 0
    [ -z "$PUBLIC_CHAT_ID" ] && return 0
    curl -s --max-time 20 -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${PUBLIC_CHAT_ID}" \
        --data-urlencode "text=${1}" \
        -d "parse_mode=Markdown" \
        -d "disable_web_page_preview=true" > /dev/null
}

START_TIME=$(date +%s)

fmt_duration() {
    local d=$(( $(date +%s) - START_TIME ))
    printf '%02d hours, %02d minutes, %02d seconds' $((d/3600)) $(( (d%3600)/60 )) $((d%60))
}

die() {
    echo "FATAL: $*" | tee -a log.txt
    echo "#### BUILD_EXIT_CODE=1 ####" | tee -a log.txt
    [ -n "$MONITOR_PID" ] && wait "$MONITOR_PID" 2>/dev/null
    send_public_telegram "❌ *ROM Build Failed!*

*ROM:* $ROM_NAME
*Device:* $DEVICE_DISPLAY
*Duration:* $(fmt_duration)
*Reason:* \`$*\`"
    exit 1
}

echo "Build Started at $(date '+%Y-%m-%d %H:%M:%S')" | tee -a log.txt

send_public_telegram "⚙️ *ROM Build Started!*

*ROM:* $ROM_NAME
*Android:* $ANDROID_VERSION
*Device:* $DEVICE_DISPLAY
*Start Time:* $(date '+%Y-%m-%d %H:%M:%S %Z')"

cat > ~/.gitconfig << 'EOF'
[user]
	name = Hafidz Muzakky
	email = ais.muzakky@gmail.com
[color]
	ui = auto
EOF
git config --global url."https://x-access-token:${GH_TOKEN}@github.com/".insteadOf "https://github.com/"
echo "DEBUG: insteadOf rule configured (token masked):" | tee -a log.txt
git config --global --get-regexp '^url\.' | sed -E 's/ghp_[A-Za-z0-9_]+/ghp_***MASKED***/g' | tee -a log.txt

repo init --depth=1 -u https://github.com/ShinkaiProject/shinkai_manifest.git -b heptakaideka --git-lfs 2>&1 | tee -a log.txt || die "repo init failed"

/opt/crave/resync.sh 2>&1 | tee -a log.txt || true
repo sync -c -j"$(nproc --all)" --force-sync --no-clone-bundle --no-tags --force-remove-dirty 2>&1 | tee -a log.txt || die "repo sync failed"
/opt/crave/resync.sh 2>&1 | tee -a log.txt || true
repo sync -c -j"$(nproc --all)" --force-sync --no-clone-bundle --no-tags --force-remove-dirty 2>&1 | tee -a log.txt || die "repo sync failed"
/opt/crave/resync.sh 2>&1 | tee -a log.txt || true

echo "Starting remove repositories..." | tee -a log.txt
rm -rf device/xiaomi/marble \
    vendor/xiaomi/marble \
    kernel/xiaomi/marble \
    kernel/xiaomi/marble-modules \
    kernel/xiaomi/marble-devicetrees \
    device/xiaomi/miuicamera-marble \
    vendor/xiaomi/miuicamera-marble \
    packages/apps/GameBar \
    packages/apps/TouchServices \
    hardware/xiaomi \
    hardware/dolby \
    out/target/product/marble \
    vendor/private/keys
echo "Successfully deleted previous repositories." | tee -a log.txt

echo "Cloning device stuff..." | tee -a log.txt
git clone https://github.com/nekoshirro/platform_device_xiaomi_marble.git device/xiaomi/marble -b shinkai-17 --depth 1 2>&1 | tee -a log.txt || die "clone device tree failed"
git clone https://github.com/nekoshirro/platform_device_xiaomi_miuicamera-marble.git -b 17 device/xiaomi/miuicamera-marble 2>&1 | tee -a log.txt || die "clone miuicamera device failed"
git clone https://github.com/nekoshirro/platform_vendor_xiaomi_marble.git -b 17 vendor/xiaomi/marble 2>&1 | tee -a log.txt || die "clone vendor tree failed"
git clone https://codeberg.org/nekoshirro/android_vendor_xiaomi_miuicamera-marble.git vendor/xiaomi/miuicamera-marble 2>&1 | tee -a log.txt || die "clone miuicamera vendor failed"
git clone --recurse-submodules https://github.com/nekoshirro/platform_kernel_xiaomi_marble.git -b 17 kernel/xiaomi/marble --depth 1 2>&1 | tee -a log.txt || die "clone kernel tree failed"
git clone https://github.com/nekoshirro/platform_kernel_xiaomi_marble-devicetrees.git kernel/xiaomi/marble-devicetrees --depth 1 2>&1 | tee -a log.txt || die "clone kernel devicetrees failed"
git clone https://github.com/nekoshirro/platform_kernel_xiaomi_marble-modules.git kernel/xiaomi/marble-modules --depth 1 2>&1 | tee -a log.txt || die "clone kernel modules failed"
git clone https://github.com/fiqri19102002/android_hardware_xiaomi.git -b lineage-24.0-cust hardware/xiaomi --depth 1 2>&1 | tee -a log.txt || die "clone hardware xiaomi failed"
git clone https://github.com/ShinkaiProject/shinkai_vendor_private_keys.git vendor/private/keys --depth 1 2>&1 | tee -a log.txt || die "clone private keys failed"


pushd frameworks/base > /dev/null || die "frameworks/base directory not found"
rm -rf revert*.patch*
wget -O revert-split-shade.patch https://raw.githubusercontent.com/nekoshirro/platform_manifest-marble/refs/heads/pixelos-16/revert-split-shade.patch 2>&1 | tee -a log.txt || die "download revert-split-shade.patch failed"
patch -N -p1 < revert-split-shade.patch 2>&1 | tee -a log.txt || true
popd > /dev/null

pushd packages/apps/Settings > /dev/null || die "packages/apps/Settings directory not found"
sed -i 's|val maintainer = SystemProperties.get(ROM_PROPERTY, "")|val maintainer = SystemProperties.get(ROM_PROPERTY, "").replace("_", " ")|' src/com/android/settings/deviceinfo/firmwareversion/ShinkaiMaintainerPreference.kt
popd > /dev/null

# TARGET_FILE="vendor/lineage/release/flag_values/cp2a/RELEASE_PLATFORM_SECURITY_PATCH.textproto"
# NEW_DATE="2026-11-01"

# if [ -f "$TARGET_FILE" ]; then
#     if grep -qE 'string_value: "[0-9]{4}-[0-9]{2}-[0-9]{2}"' "$TARGET_FILE"; then
#         sed -i -E "s/string_value: \"[0-9]{4}-[0-9]{2}-[0-9]{2}\"/string_value: \"${NEW_DATE}\"/" "$TARGET_FILE"
#         echo "[patch] OK -> ${NEW_DATE}" | tee -a log.txt
#     else
#         die "Security patch hack failed: date pattern not found in $TARGET_FILE"
#     fi
# else
#     die "Security patch hack failed: file not found: $TARGET_FILE"
# fi

for d in vendor/xiaomi/marble vendor/xiaomi/miuicamera-marble; do
    if [ -d "$d" ]; then
        echo "Pulling LFS assets for $d..." | tee -a log.txt
        (git -C "$d" lfs install && git -C "$d" lfs pull && git -C "$d" lfs fetch --all) 2>&1 | tee -a log.txt || die "LFS pull failed: $d"
    fi
done

echo "Tree sync complete." | tee -a log.txt

. build/envsetup.sh > >(tee -a log.txt) 2>&1 || die "envsetup failed"
echo "Environment setup success." | tee -a log.txt

lunch shinkai_marble-cp2a-user > >(tee -a log.txt) 2>&1 || die "lunch failed"
echo "Lunch command executed." | tee -a log.txt

(
    while true; do
        echo "[memmon] === $(date +%T) ==="
        echo "[memmon] $(free -m | sed -n 2p)"
        echo "[memmon] cg.max=$(cat /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null | head -1) cg.peak=$(cat /sys/fs/cgroup/memory.peak /sys/fs/cgroup/memory/memory.max_usage_in_bytes 2>/dev/null | head -1)"
        ps -eo rss,comm --sort=-rss | head -4 | sed 's/^/[memmon] /'
        sleep 15
    done
) >> log.txt 2>&1 &
MEMMON_PID=$!
trap 'kill $MEMMON_PID 2>/dev/null' EXIT

echo "=========================" | tee -a log.txt
echo "Starting ROM Compilation..." | tee -a log.txt
echo "=========================" | tee -a log.txt

m shinkai -j"$(nproc --all)" 2>&1 | tee -a log.txt
BUILD_STATUS=${PIPESTATUS[0]}

kill $MEMMON_PID 2>/dev/null || true

DURATION_FMT="$(fmt_duration)"

if [ "$BUILD_STATUS" -eq 0 ]; then
    echo "Uploading ROM..." | tee -a log.txt
    ROM_ZIP=$(ls out/target/product/marble/*marble*.zip 2>/dev/null | head -1)

    if [ -n "$ROM_ZIP" ] && wget -qO go-up https://raw.githubusercontent.com/nekoshirro/tools-gofile/refs/heads/private/go-up && [ -s go-up ]; then
        chmod +x go-up
        ./go-up "$ROM_ZIP" 2>&1 | tee -a log.txt
    fi
    rm -f go-up

    echo "#### BUILD_EXIT_CODE=0 ####" | tee -a log.txt
    [ -n "$MONITOR_PID" ] && wait "$MONITOR_PID" 2>/dev/null

    send_public_telegram "✅ *ROM Build Finished Successfully!*

*ROM:* $ROM_NAME
*Device:* $DEVICE_DISPLAY
*Android:* $ANDROID_VERSION
*Duration:* $DURATION_FMT"
else
    echo "#### BUILD_EXIT_CODE=$BUILD_STATUS ####" | tee -a log.txt
    [ -n "$MONITOR_PID" ] && wait "$MONITOR_PID" 2>/dev/null

    send_public_telegram "❌ *ROM Build Failed!*

*ROM:* $ROM_NAME
*Device:* $DEVICE_DISPLAY
*Duration:* $DURATION_FMT
*Status:* Compilation Error (Code: $BUILD_STATUS)"
fi

rm -f monitor.py
exit "$BUILD_STATUS"
