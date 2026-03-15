#!/bin/bash
set -o pipefail

for sec in "/tmp/src/android/.secrets" "$HOME/.secrets" "$PWD/.secrets"; do
    [ -f "$sec" ] && source "$sec"
done

: > log.txt

export DEVICE_CODE="marble"
export DEVICE_DISPLAY="Redmi Note 12 Turbo"
export ROM_NAME="Evolution-X"
export ANDROID_VERSION="17"
export BUILD_TARGET="Evolution-X"
export TARGET_PRODUCT="lineage_marble"
export BUILD_VARIANT="user"
export BUILD_USERNAME="hafidz"
export BUILD_HOSTNAME="alchemist"
export TZ="Asia/Jakarta"

PUBLIC_CHAT_ID="${TG_BUILD_CHAT_ID:-}"

MONITOR_PID=""
if wget -qO monitor.py "https://raw.githubusercontent.com/nekoshirro/platform_manifest-marble/refs/heads/evox-17/monitor.py" && [ -s monitor.py ]; then
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

rm -f .repo/local_manifests/remove_gms.xml
repo init -u https://github.com/Evolution-X/manifest -b cnb --git-lfs --depth 1 2>&1 | tee -a log.txt || die "repo init failed"
/opt/crave/resync.sh 2>&1 | tee -a log.txt

sync_all() {
    repo sync -c -j"$(nproc --all)" --force-sync --force-remove-dirty --no-clone-bundle --no-tags 2>&1 | tee -a log.txt
}

GMS_FALLBACK=0
if ! sync_all; then
    if [ -d ".repo/projects/vendor/gms.git" ]; then
        git -C .repo/projects/vendor/gms.git config lfs.url "https://gitea.com/Evolution-X/blobs.git/info/lfs" || true
    fi
    if ! sync_all; then
        echo "WARNING: repo sync failed, retrying without vendor/gms (using Codeberg fallback)..." | tee -a log.txt
        mkdir -p .repo/local_manifests
        cat > .repo/local_manifests/remove_gms.xml << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<manifest>
  <remove-project name="vendor_gms" />
</manifest>
EOF
        rm -rf vendor/gms
        sync_all || die "repo sync failed"
        GMS_FALLBACK=1
    fi
fi
/opt/crave/resync.sh 2>&1 | tee -a log.txt
rm -f .repo/local_manifests/remove_gms.xml

rm -rf device/xiaomi/marble* device/xiaomi/miuicamera-marble \
    vendor/xiaomi/marble* vendor/xiaomi/miuicamera-marble \
    kernel/xiaomi/marble* \
    hardware/{xiaomi,dolby} packages/apps/{GameBar,TouchServices,Settings} \
    vendor/{evolution,lineage}* out/target/product/marble frameworks/base

git clone https://github.com/nekoshirro/platform_device_xiaomi_marble.git -b evox-17 device/xiaomi/marble --depth 1 2>&1 | tee -a log.txt || die "clone device tree failed"
git clone https://github.com/nekoshirro/platform_device_xiaomi_miuicamera-marble.git -b 17 device/xiaomi/miuicamera-marble 2>&1 | tee -a log.txt || die "clone miuicamera device failed"
git clone https://github.com/nekoshirro/platform_vendor_xiaomi_marble.git -b 17 vendor/xiaomi/marble 2>&1 | tee -a log.txt || die "clone vendor tree failed"
git clone https://codeberg.org/nekoshirro/android_vendor_xiaomi_miuicamera-marble.git -b main vendor/xiaomi/miuicamera-marble 2>&1 | tee -a log.txt || die "clone miuicamera vendor failed"
git clone --recurse-submodules https://github.com/nekoshirro/platform_kernel_xiaomi_marble.git -b 17 kernel/xiaomi/marble --depth 1 2>&1 | tee -a log.txt || die "clone kernel tree failed"
git clone https://github.com/nekoshirro/platform_kernel_xiaomi_marble-devicetrees.git kernel/xiaomi/marble-devicetrees --depth 1 2>&1 | tee -a log.txt || die "clone kernel devicetrees failed"
git clone https://github.com/nekoshirro/platform_kernel_xiaomi_marble-modules.git kernel/xiaomi/marble-modules --depth 1 2>&1 | tee -a log.txt || die "clone kernel modules failed"
git clone https://github.com/Evolution-X-Devices/hardware_xiaomi.git -b cnb-no-dolby hardware/xiaomi --depth 1 2>&1 | tee -a log.txt || die "clone hardware xiaomi failed"
git clone https://github.com/Evolution-X/vendor_evolution.git -b cnb vendor/lineage --depth 1 2>&1 | tee -a log.txt || die "clone vendor lineage failed"
git clone https://github.com/Evolution-X/packages_apps_Settings.git -b cnb packages/apps/Settings --depth 1 2>&1 | tee -a log.txt || die "clone Settings failed"
git clone https://github.com/Evolution-X/frameworks_base.git -b cnb frameworks/base --depth 1 2>&1 | tee -a log.txt || die "clone frameworks base failed"

for d in vendor/xiaomi/marble vendor/xiaomi/miuicamera-marble; do
    if [ -d "$d" ]; then
        echo "Pulling LFS assets for $d..." | tee -a log.txt
        (git -C "$d" lfs install && git -C "$d" lfs pull && git -C "$d" lfs fetch --all) 2>&1 | tee -a log.txt || die "LFS pull failed: $d"
    fi
done

sync_gms_mirror() {
    echo "WARNING: vendor/gms sync or LFS failed, falling back to Codeberg mirror..." | tee -a log.txt
    rm -rf vendor/gms
    git clone https://codeberg.org/nekoshirro/vendor_gms.git -b cnb vendor/gms --depth 1 2>&1 | tee -a log.txt || die "clone vendor/gms mirror failed"
    (git -C vendor/gms lfs install && git -C vendor/gms lfs pull && git -C vendor/gms lfs fetch --all) 2>&1 | tee -a log.txt || die "LFS pull failed: vendor/gms mirror"
}

if [ "$GMS_FALLBACK" -eq 1 ] || [ ! -e "vendor/gms/.git" ]; then
    sync_gms_mirror
else
    echo "Pulling LFS assets for vendor/gms..." | tee -a log.txt
    if ! (git -C vendor/gms lfs install && git -C vendor/gms lfs pull && git -C vendor/gms lfs fetch --all) 2>&1 | tee -a log.txt; then
        git -C vendor/gms config lfs.url "https://gitea.com/Evolution-X/blobs.git/info/lfs" || true
        (git -C vendor/gms lfs install && git -C vendor/gms lfs pull && git -C vendor/gms lfs fetch --all) 2>&1 | tee -a log.txt || sync_gms_mirror
    fi
fi

pushd build/soong > /dev/null || die "build/soong directory not found"
grep -q "func HighmemPool()" android/defs.go || sed -i '/highmemPool = blueprint.NewBuiltinPool("highmem_pool")/!b;n;a\\nfunc HighmemPool() blueprint.Pool {\n\treturn highmemPool\n}' android/defs.go
grep -q "ruleParamsRE.Pool = nil" android/package_ctx.go || sed -i '/func (p PackageContext) MultiCommandRemoteStaticRules/,/ruleParamsRE := ruleParams/ s/\(ruleParamsRE := ruleParams\)/\1\n\truleParamsRE.Pool = nil/' android/package_ctx.go
grep -q "Pool: android.HighmemPool()" java/dex.go || {
    sed -i '/var d8IncR8, d8IncR8RE =/,/CommandDeps:/ s/^\(\t\tCommandDeps:\)/\t\tPool: android.HighmemPool(),\n\1/' java/dex.go
    sed -i '/var d8r8, d8r8RE =/,/CommandDeps:/ s/^\(\t\tCommandDeps:\)/\t\tPool: android.HighmemPool(),\n\1/' java/dex.go
    sed -i '/var r8, r8RE =/,/CommandDeps:/ s/^\(\t\tCommandDeps:\)/\t\tPool:    android.HighmemPool(),\n\1/' java/dex.go
}
grep -q "runtime/debug" cmd/soong_build/main.go || sed -i '/"runtime"/a \\t"runtime/debug"' cmd/soong_build/main.go
grep -q "SetMemoryLimit" cmd/soong_build/main.go || sed -i '/func main() {/a \\tdebug.SetMemoryLimit(40 * 1024 * 1024 * 1024)\n\tdebug.SetGCPercent(25)\n' cmd/soong_build/main.go

grep -q "func HighmemPool()" android/defs.go || die "Soong patch failed: HighmemPool() missing"
grep -q "android.HighmemPool()" java/dex.go || die "Soong patch failed: dex.go pool missing"
if grep -q "SetMemoryLimit" cmd/soong_build/main.go && ! grep -q '"runtime/debug"' cmd/soong_build/main.go; then
    die "Soong patch failed: SetMemoryLimit without runtime/debug import"
fi
if grep -q '"runtime/debug"' cmd/soong_build/main.go && ! grep -q "debug\.SetMemoryLimit" cmd/soong_build/main.go; then
    die "Soong patch failed: unused runtime/debug import"
fi
popd > /dev/null

grep -q "KATI_NINJA_POOL := highmem_pool" vendor/lineage/build/tasks/kernel.mk 2>/dev/null || \
    sed -i '/\$(TARGET_PREBUILT_INT_KERNEL): \$(KERNEL_CONFIG)/i \$(TARGET_PREBUILT_INT_KERNEL): .KATI_NINJA_POOL := highmem_pool' vendor/lineage/build/tasks/kernel.mk 2>/dev/null || true

UPDATER_STRINGS="packages/apps/Updater/app/src/main/res/values/strings.xml"
[ -f "$UPDATER_STRINGS" ] || die "Updater strings.xml not found"
sed -i 's|https://raw.githubusercontent.com/Evolution-X/OTA/cnb/|https://raw.githubusercontent.com/nekoshirro/OTA/main/|' "$UPDATER_STRINGS"
grep -q "nekoshirro/OTA" "$UPDATER_STRINGS" || die "OTA URL patch failed"

PATCH_BASE="https://raw.githubusercontent.com/nekoshirro/platform_manifest-marble/refs/heads/evox-17"
curl -fsSL "$PATCH_BASE/nekoshirro-maintainer.patch" -o /tmp/maintainer.patch || die "Download maintainer.patch failed"
patch -d packages/apps/Settings -p1 < /tmp/maintainer.patch 2>&1 | tee -a log.txt || die "Apply maintainer.patch failed"
curl -fsSL "$PATCH_BASE/device-image-lineage-marble.patch" -o /tmp/device-image.patch || die "Download device-image patch failed"
git -C packages/apps/Settings apply /tmp/device-image.patch 2>&1 | tee -a log.txt || die "Apply device-image patch failed"
rm -f /tmp/maintainer.patch /tmp/device-image.patch

TARGET_FILE="vendor/lineage/release/flag_values/cp2a/RELEASE_PLATFORM_SECURITY_PATCH.textproto"
if [ -f "$TARGET_FILE" ]; then
    sed -i -E 's/string_value: "[0-9]{4}-[0-9]{2}-[0-9]{2}"/string_value: "2026-10-01"/' "$TARGET_FILE"
fi

WP_DST="vendor/lineage/overlay/common/frameworks/base/core/res/res/drawable-nodpi/default_wallpaper.png"
if wget -q -O /tmp/default_wallpaper.png "$PATCH_BASE/default_wallpaper.png" && [ -s /tmp/default_wallpaper.png ]; then
    cp /tmp/default_wallpaper.png "$WP_DST"
fi
rm -f /tmp/default_wallpaper.png

if [ -n "$PRIV_KEYS_REPO" ]; then
    git clone "$PRIV_KEYS_REPO" vendor/evolution-priv/keys --depth 1 2>&1 | tee -a log.txt || die "Clone private keys repo failed"
else
    git clone https://github.com/Evolution-X/vendor_evolution-priv_keys-template vendor/evolution-priv/keys --depth 1 2>&1 | tee -a log.txt || die "Clone keys template failed"
    (cd vendor/evolution-priv/keys && chmod +x keys.sh && printf '\n\n\n\n\n\n\n\n' | ./keys.sh || true) 2>&1 | tee -a log.txt
    if [ ! -f "vendor/evolution-priv/keys/testkey.pk8" ] || [ ! -f "vendor/evolution-priv/keys/com.qorvo.uwb.certificate.override.pk8" ]; then
        die "Generating signing keys failed: missing generated keys"
    fi
fi

. build/envsetup.sh > >(tee -a log.txt) 2>&1 || die "envsetup failed"
lunch lineage_marble-cp2a-user > >(tee -a log.txt) 2>&1 || die "lunch failed"

(
    while true; do
        echo "[memmon] === $(date +%T) ==="
        echo "[memmon] $(free -m | sed -n 2p)"
        sleep 15
    done
) >> log.txt 2>&1 &
MEMMON_PID=$!
trap 'kill $MEMMON_PID 2>/dev/null' EXIT

echo "Starting ROM Compilation..." | tee -a log.txt
m evolution -j"$(nproc --all)" 2>&1 | tee -a log.txt
BUILD_STATUS=${PIPESTATUS[0]}

kill $MEMMON_PID 2>/dev/null || true

DURATION_FMT="$(fmt_duration)"

if [ "$BUILD_STATUS" -eq 0 ]; then
    echo "Uploading ROM..." | tee -a log.txt
    ROM_ZIP=$(ls out/target/product/marble/Evolution*marble*.zip 2>/dev/null | head -1)
    GOLINK=""
    PXLINK=""

    if [ -n "$ROM_ZIP" ] && wget -qO go-up https://raw.githubusercontent.com/nekoshirro/tools-gofile/refs/heads/private/go-up && [ -s go-up ]; then
        chmod +x go-up
        UPLOAD_OUTPUT=$(./go-up "$ROM_ZIP" 2>&1 | tee -a log.txt)
        GOLINK=$(echo "$UPLOAD_OUTPUT" | grep -oE 'https://gofile\.io/d/[a-zA-Z0-9]+' | head -1)
        PXLINK=$(echo "$UPLOAD_OUTPUT" | grep -oE 'https://pixeldrain\.com/u/[a-zA-Z0-9]+' | head -1)
    fi
    rm -f go-up

    echo "#### BUILD_EXIT_CODE=0 ####" | tee -a log.txt
    [ -n "$MONITOR_PID" ] && wait "$MONITOR_PID" 2>/dev/null

    LINKS_TEXT=""
    [ -n "$GOLINK" ] && LINKS_TEXT="${LINKS_TEXT}🔗 [Gofile Download Link](${GOLINK})"$'\n'
    [ -n "$PXLINK" ] && LINKS_TEXT="${LINKS_TEXT}🔗 [Pixeldrain Download Link](${PXLINK})"$'\n'

    if [ -n "$LINKS_TEXT" ]; then
        send_public_telegram "✅ *ROM Build Finished Successfully!*

*ROM:* $ROM_NAME
*Device:* $DEVICE_DISPLAY
*Android:* $ANDROID_VERSION
*Duration:* $DURATION_FMT

*Download Links:*
${LINKS_TEXT}"
    else
        send_public_telegram "⚠️ *ROM Build Finished!*

*ROM:* $ROM_NAME
*Device:* $DEVICE_DISPLAY
*Android:* $ANDROID_VERSION
*Duration:* $DURATION_FMT
*Status:* Build succeeded, but upload failed or links unavailable."
    fi
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
