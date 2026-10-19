#!/bin/bash
# Builds everything into ./build. Installing is a separate, manual step (see README).
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build/AutoGPU.app/Contents/MacOS

clang -fobjc-arc -O2 -Wall -Wextra -Wno-unused-parameter \
    -framework Cocoa -framework IOKit -framework CoreAudio -framework CoreGraphics -framework CoreServices \
    src/auto-gpu-switcher.m -o build/AutoGPU.app/Contents/MacOS/AutoGPU
cp app/Info.plist build/AutoGPU.app/Contents/Info.plist
codesign --force --sign - build/AutoGPU.app

clang -O2 -Wall -Wextra -framework IOKit src/smc-fan-helper.c -o build/smc-fan-helper
clang -O2 -Wall -Wextra src/mac27-prewarmer.c -o build/mac27-prewarmer

echo "Built: build/AutoGPU.app build/smc-fan-helper build/mac27-prewarmer"
