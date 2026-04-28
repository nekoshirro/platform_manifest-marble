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
BUILD_TARGET="The Clover Project"
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

    # Init The Clover Project
    repo init -u https://github.com/The-Clover-Project/manifest.git -b 16-qpr2 --git-lfs

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
    rm -rf hardware/xiaomi
    rm -rf hardware/dolby
    rm -rf packages/apps/GameBar
    rm -rf packages/apps/EuiccPolicy
    rm -rf out/target/product/marble
    rm -rf vendor/*priv*
    rm -rf vendor/clover-priv*
    rm -rf vendor/clover/*priv*
    rm -rf vendor/*lineage-priv*
    rm -rf vendor/certification
    echo "Successfully deleted previous repositories."

    echo "Cloning device stuff..."
    # Device Trees
    git clone https://github.com/nekoshirro/platform_device_xiaomi_marble.git device/xiaomi/marble -b clover-16 --depth 1
    git clone https://github.com/fiqri19102002/android_device_xiaomi_miuicamera-marble.git device/xiaomi/miuicamera-marble
    git clone https://github.com/nekoshirro/platform_vendor_xiaomi_marble.git -b 16 vendor/xiaomi/marble
    git clone https://codeberg.org/fiqri19102002/proprietary_vendor_xiaomi_miuicamera-marble.git vendor/xiaomi/miuicamera-marble
    git clone --recurse-submodules https://github.com/nekoshirro/platform_kernel_xiaomi_marble.git -b 16 kernel/xiaomi/marble --depth 1
    git clone https://github.com/nekoshirro/platform_kernel_xiaomi_marble-devicetrees.git kernel/xiaomi/marble-devicetrees --depth 1
    git clone https://github.com/nekoshirro/platform_kernel_xiaomi_marble-modules.git kernel/xiaomi/marble-modules --depth 1
    git clone https://github.com/Evolution-X-Devices/hardware_xiaomi.git -b bka-no-dolby hardware/xiaomi --depth 1
    git clone https://github.com/LineageOS/android_packages_apps_EuiccPolicy packages/apps/EuiccPolicy
    git clone https://github.com/nekoshirro/android_vendor_certification.git vendor/certification

    pushd vendor/xiaomi/marble
    git lfs install
    git lfs pull
    popd

    pushd vendor/xiaomi/miuicamera-marble
    git lfs install
    git lfs pull
    popd

    pushd hardware/xiaomi
    git fetch https://github.com/RiteshSahany/hardware_xiaomi.git
    git cherry-pick -X theirs 1b5c189715c31fc4102e5b5e8278183f0061d272
    popd

    echo "Tree sync complete."

    # Sign with The Clover Project keys
    git clone https://github.com/nekoshirro/android_vendor_priv-keys.git -b clover vendor/clover-priv/keys
    pushd vendor/clover-priv/keys
    chmod +x keys.sh
    ./keys.sh
    popd

    # Google Gemini Bootanimation
    pushd vendor/clover/bootanimation
    rm -rf bootanimation_1080.zip
    wget https://github.com/PixelOS-AOSP/android_vendor_custom/raw/refs/heads/sixteen-qpr2/bootanimation/bootanimation_1080.zip
    popd

    # Setup the build environment
    . build/envsetup.sh
    echo "Environment setup success."

    # Lunch target selection
    lunch clover_marble-bp4a-user
    echo "Lunch command executed."

    # Build ROM
    echo "========================="
    echo "Starting ROM Compilation..."
    echo "========================="
    m clover -j$(nproc --all) 2>&1 | tee log.txt

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
        ./go-up out/target/product/marble/Clover*marble*.zip
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
