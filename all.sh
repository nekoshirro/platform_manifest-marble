#!/bin/bash

BASE_URL="https://raw.githubusercontent.com/nekoshirro/platform_manifest-marble/refs/heads/kernel"
FAILED=""

for script in non-root.sh resukisu.sh kernelsu-next.sh sukisu.sh; do
    rm -f "$script"
    if wget -qO "$script" "${BASE_URL}/${script}" && [ -s "$script" ]; then
        chmod +x "$script"
        ./"$script" || FAILED="$FAILED $script"
        export SKIP_SYNC=1
    else
        echo "WARNING: Failed to download $script"
        FAILED="$FAILED $script"
    fi
    rm -f "$script"
done

[ -z "$FAILED" ] || { echo "Failed variants:$FAILED"; exit 1; }
