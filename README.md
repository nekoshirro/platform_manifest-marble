# Evolution-X AOSP Build Manifest for Redmi Note 12 Turbo / POCO F5 (marble)

Created and maintained by @nekoshirro — optimized for CI-based AOSP builds on Redmi Note 12 Turbo / POCO F5 (codename: marble)

This repository provides a customized repo manifest designed specifically for building Android Open Source Project (AOSP) ROMs for the marble device, with CI (Continuous Integration) compatibility in mind.

# Requirements:
- Linux build environment (Ubuntu 20.04 or later recommended)
- Git and repo tool installed
- At least 200 GB of free disk space
- At least 16 GB RAM (32 GB recommended)

# Usage:
Run this command on your root ROM directory:

```bash
curl https://raw.githubusercontent.com/nekoshirro/platform_manifest-marble/refs/heads/evox/evolution.sh | bash
```

This script will:
1. Initialize the repo using the customized manifest
2. Sync all required sources
3. Start the AOSP build process for marble

# CI Integration:
This manifest is tested for use with:
- [CirrusCI](https://cirrus-ci.org/)
- [crave.io](https://foss.crave.io/app/#/)
- Local Jenkins Pipelines

You can easily incorporate the manifest into your CI system by using the provided build.sh script.

# Troubleshooting:
- Build errors? Ensure your build environment meets all AOSP requirements.
- Repo sync fails? Try running: repo sync -j$(nproc --all) --force-sync
- Device tree missing? Check the manifest for correct remote links.
- Slow sync? Use a closer AOSP mirror if available.

# License:
Licensed under the MIT License

# Credits:
- Maintained by @nekoshirro
- Based on AOSP manifests and open-source device trees
- Inspired by the Android custom ROM community and automated CI workflows
