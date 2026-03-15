#!/bin/bash

wget https://raw.githubusercontent.com/nekoshirro/platform_manifest-marble/refs/heads/kernel/resukisu.sh
chmod +x resukisu.sh
./resukisu.sh

wget https://raw.githubusercontent.com/nekoshirro/platform_manifest-marble/refs/heads/kernel/kernelsu-next.sh
chmod +x kernelsu-next.sh
./kernelsu-next.sh
