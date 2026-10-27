#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/test-setup.py
python3 scripts/test-private-setup.py
./scripts/build.sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache" \
  swift test --cache-path "$PWD/.build/cache" --disable-sandbox
MTL_DEBUG_LAYER=1 "build/Live2D Avatar.app/Contents/MacOS/Live2DAvatar" \
  --smoke-test "$PWD/build/verification"
