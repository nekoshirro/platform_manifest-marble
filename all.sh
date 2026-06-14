#!/bin/bash

# Non-root Kernel
rm -rf non-root.sh
wget https://raw.githubusercontent.com/nekoshirro/platform_manifest-marble/refs/heads/kernel/non-root.sh
chmod +x non-root.sh
./non-root.sh
rm -rf non-root.sh

# ReSukiSU Kernel
rm -rf resukisu.sh
wget https://raw.githubusercontent.com/nekoshirro/platform_manifest-marble/refs/heads/kernel/resukisu.sh
chmod +x resukisu.sh
./resukisu.sh
rm -rf resukisu.sh

# KernelSU-Next kernel
rm -rf kernelsu-next.sh
wget https://raw.githubusercontent.com/nekoshirro/platform_manifest-marble/refs/heads/kernel/kernelsu-next.sh
chmod +x kernelsu-next.sh
./kernelsu-next.sh
rm -rf kernelsu-next.sh
