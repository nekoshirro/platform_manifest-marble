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
# CONFIGURATION
# =========================================================
# This token was retrieved from your previous log for continuous functionality.
DEVICE_CODE="marble"
BUILD_TARGET="PixelOS"
ANDROID_VERSION="16.2"

# SHELL CONFIGURATION
export TZ="Asia/Jakarta"
export BUILD_USERNAME=hafidz
export BUILD_HOSTNAME=alchemist

# =========================================================
# TELEGRAM FUNCTIONS
# =========================================================

# Function to safely format and send a text message to Telegram
send_telegram() {
  local chat_id="$1"
  local message="$2"
  local _TK="$TG_BOT_TOKEN"

  # 1. Escape characters required by MarkdownV2 that are NOT meant to be formatters.
  # We use a comprehensive escaping logic to ensure *bold* text works.
  local escaped_message=$(echo "$message" | sed \
    -e 's/\*/\*TEMP\*/g' \
    -e 's/_/\_TEMP\_/g' \
    -e 's/\[/\\[/g' \
    -e 's/\]/\\]/g' \
    -e 's/(/\\(/g' \
    -e 's/)/\\)/g' \
    -e 's/~/\\~/g' \
    -e 's/`/\`/g' \
    -e 's/>/\\>/g' \
    -e 's/#/\\#/g' \
    -e 's/+/\\+/g' \
    -e 's/-/\\-/g' \
    -e 's/=/\\=/g' \
    -e 's/|/\\|/g' \
    -e 's/{/\\{/g' \
    -e 's/}/\\}/g' \
    -e 's/\./\\./g' \
    -e 's/!/\\!/g')

  # 2. Revert the temporary placeholders for the actual formatting characters that are intended for bold/italic.
  local re_escaped_message=$(echo "$escaped_message" | sed \
    -e 's/\*TEMP\*/\*/g' \
    -e 's/\_TEMP\_/\_/g')
  
  # 3. URL encode special characters for transmission, including newlines.
  local encoded_message=$(echo "$re_escaped_message" | sed \
    -e 's/%/%25/g' \
    -e 's/&/%26/g' \
    -e 's/+/%2b/g' \
    -e 's/ /%20/g' \
    -e 's/\"/%22/g' \
    -e 's/'"'"'/%27/g' \
    -e 's/\n/%0A/g')
    
  echo -e "\n[$(date '+%Y-%m-%d %H:%M:%S')] Sending message to Telegram (${chat_id})"
  # We must explicitly set parse_mode to MarkdownV2
  curl -s -X POST "https://api.telegram.org/bot${_TK}/sendMessage" \
    -d "chat_id=${chat_id}" \
    -d "text=${encoded_message}" \
    -d "parse_mode=MarkdownV2" \
    -d "disable_web_page_preview=true" > /dev/null
}

send_telegram_file() {

  local chat_id="$1"
  local file_path="$2"
  local caption="$3"

  if [ ! -f "$file_path" ]; then
    echo "Error: File $file_path not found!"
    return 1
  fi

  echo -e "\n[$(date '+%Y-%m-%d %H:%M:%S')] Sending document to Telegram (${chat_id})"

  curl -s -X POST "https://api.telegram.org/bot${_TK}/sendDocument" \
    -F "chat_id=${chat_id}" \
    -F "document=@${file_path}" \
    -F "caption=${caption}" \
    -F "parse_mode=MarkdownV2" > /dev/null
}

# Function to format total seconds into HH:MM:SS string
format_duration() {
    local T=$1
    local H=$((T/3600))
    local M=$(( (T%3600)/60 ))
    local S=$((T%60))
    printf "%02d hours, %02d minutes, %02d seconds" $H $M $S
}


# =========================================================
# BUILD LOGIC FUNCTION
# =========================================================

start_build_process() {

    # --- STEP 1: START TIMER AND SEND INITIAL NOTIFICATION ---
    START_TIME=$(date +%s)

    # Message for Build Started
    local initial_msg="⚙️ *ROM Build Started!*

    *ROM:* $BUILD_TARGET
    *Android:* $ANDROID_VERSION
    *Device:* $DEVICE_CODE
    *Start Time:* $(date '+%Y-%m-%d %H:%M:%S %Z')"
    send_telegram "$TG_BUILD_CHAT_ID" "$initial_msg"
    echo "Build Started at $(date '+%Y-%m-%d %H:%M:%S')"

    # =========================================================
    # ORIGINAL BUILD STEPS
    # =========================================================

    # Init PixelOS 16.2 (POS-GM)
    rm -rf frameworks/base build/soong prebuilt
    repo init -u https://github.com/pos-gm/android_manifest.git -b sixteen-qpr2 --git-lfs --depth 1

    # Resync sources
    /opt/crave/resync.sh
    repo sync -c -j$(nproc --all) --force-sync --no-clone-bundle --no-tags
    /opt/crave/resync.sh
    repo sync -c -j$(nproc --all) --force-sync --no-clone-bundle --no-tags
    /opt/crave/resync.sh

    # Clean up existing trees
    echo "Starting remove repositories..."
    rm -rf device/xiaomi/marble
    rm -rf vendor/xiaomi/marble
    rm -rf kernel/xiaomi/marble
    rm -rf kernel/xiaomi/marble-modules
    rm -rf kernel/xiaomi/marble-devicetrees
    rm -rf device/xiaomi/miuicamera-marble
    rm -rf vendor/xiaomi/miuicamera-marble
    rm -rf packages/apps/GameBar
    rm -rf packages/apps/TouchServices
    rm -rf hardware/xiaomi
    rm -rf hardware/dolby
    rm -rf out/target/product/marble
    rm -rf vendor/custom/signing
    rm -rf vendor/lineage
    rm -rf frameworks/base
    echo "Successfully deleted previous repositories."

    echo "Cloning device stuff..."
    # Device Trees
    git clone https://github.com/nekoshirro/platform_device_xiaomi_marble.git device/xiaomi/marble -b pixelos-16 --depth 1
    git clone https://github.com/fiqri19102002/android_device_xiaomi_miuicamera-marble.git -b lineage-23.2 device/xiaomi/miuicamera-marble
    git clone https://github.com/nekoshirro/platform_vendor_xiaomi_marble.git -b 16 vendor/xiaomi/marble
    git clone https://codeberg.org/fiqri19102002/proprietary_vendor_xiaomi_miuicamera-marble.git -b lineage-23.2 vendor/xiaomi/miuicamera-marble
    git clone --recurse-submodules https://github.com/nekoshirro/platform_kernel_xiaomi_marble.git -b 16 kernel/xiaomi/marble --depth 1
    git clone https://github.com/nekoshirro/platform_kernel_xiaomi_marble-devicetrees.git kernel/xiaomi/marble-devicetrees --depth 1
    git clone https://github.com/nekoshirro/platform_kernel_xiaomi_marble-modules.git kernel/xiaomi/marble-modules --depth 1
    git clone https://github.com/nekoshirro/android_hardware_xiaomi.git hardware/xiaomi --depth 1 -b pixelos-16
    git clone https://codeberg.org/fiqri19102002/vendor_custom_signing-keys.git vendor/custom/signing
    git clone https://github.com/pos-gm/android_vendor_lineage.git vendor/lineage --depth 1
    git clone https://github.com/pos-gm/android_frameworks_base.git frameworks/base --depth 1

    pushd build/soong
    git fetch --unshallow
    git remote add fiqri https://github.com/fiqri19102002/android_build_soong.git
    git fetch fiqri
    git cherry-pick 7d0dc9b2556c684e94d09564b6d38598314b93df 479ca4d056a241e7a5994b0e6ba71c9247eed29d
    popd

    echo "Patching time!"
#    pushd vendor/lineage
#    rm -rf sec*.patch*
#    wget -O security-patch.patch https://raw.githubusercontent.com/nekoshirro/platform_manifest-marble/refs/heads/pixelos-16/security-patch.patch
#    patch -N -p1 < security-patch.patch
#    popd

    pushd frameworks/base
    rm -rf revert*.patch*
    wget -O revert-split-shade.patch https://raw.githubusercontent.com/nekoshirro/platform_manifest-marble/refs/heads/pixelos-16/revert-split-shade.patch
    patch -N -p1 < revert-split-shade.patch
    popd

    pushd vendor/custom/overlay/rro_packages/FrameworkOverlayCustom/res
    rm -f drawable-hdpi/default_wallpaper.png
    rm -f drawable-xhdpi/default_wallpaper.png
    rm -f drawable-xxhdpi/default_wallpaper.png
    rm -f drawable-xxxhdpi/default_wallpaper.png

    rm -f drawable-nodpi/default_wallpaper.png
    wget -O drawable-nodpi/default_wallpaper.png https://raw.githubusercontent.com/nekoshirro/platform_manifest-marble/evox-17/default_wallpaper.png
    popd

    pushd vendor/xiaomi/marble
    git lfs install
    git lfs pull
    popd

    pushd vendor/xiaomi/miuicamera-marble
    git lfs install
    git lfs pull
    popd

    echo "Tree sync complete."

    # Setup the build environment
    . build/envsetup.sh
    echo "Environment setup success."

    # Lunch target selection
    lunch custom_marble-bp4a-user
    echo "Lunch command executed."

    # Build ROM
    echo "========================="
    echo "Starting ROM Compilation..."
    echo "========================="
    m pixelos -j$(nproc --all) 2>&1 | tee log.txt

    BUILD_STATUS=$? # Capture exit code immediately

    # --- STEP 3: CALCULATE TIME AND SEND FINAL NOTIFICATION ---
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))
    
    local DURATION_FORMATTED=$(format_duration $DURATION)
    
    if [[ $BUILD_STATUS -eq 0 ]]; then
        local status_icon="✅"
        local status_text="Success"
	LOG_FILE="log.txt"
    else
        local status_icon="❌"
        local status_text="Failure (Exit Code: $BUILD_STATUS)"
	LOG_FILE="out/error.log"
    fi

    # Final Message with Android Version
    local final_msg="${status_icon} *Build Finished!*

    *ROM:* $BUILD_TARGET
    *Android:* $ANDROID_VERSION
    *Device:* $DEVICE_CODE
    *Duration:* $DURATION_FORMATTED
    *Status:* $status_text"
    send_telegram "$TG_BUILD_CHAT_ID" "$final_msg"

    if [[ -f "$LOG_FILE" ]]; then
	send_telegram_file "$TG_BUILD_CHAT_ID" "$LOG_FILE"
    else
	send_telegram "$TG_BUILD_CHAT_ID" "⚠️ Warning: Log file ${LOG_FILE} not found."
    fi

    # Conditional Upload ROM
    if [[ $BUILD_STATUS -eq 0 ]]; then
        echo "Build successful. Starting upload script..."
        # Calls the go-up script
        rm -rf go-up*
        wget https://raw.githubusercontent.com/nekoshirro/tools-gofile/refs/heads/private/go-up
        chmod +x go-up
        ./go-up out/target/product/marble/Pixel*marble*.zip
    else
        echo "Build failed. Skipping upload."
    fi

    # Display any error logs
    echo "Here is your error"
    cat out/error.log
}

# =========================================================
# MAIN EXECUTION
# =========================================================

# Check required environment variables (optional but good practice)
start_build_process
