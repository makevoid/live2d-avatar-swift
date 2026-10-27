#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ ! -f vendor/swift-cubism/Core/Live2DCubismCore.xcframework/Info.plist || ! -f local-assets/Haru/Haru.model3.json ]]; then
  echo 'Run python3 scripts/setup.py --sdk-zip /path/to/CubismSdkForNative-5-r.4.1.zip first.' >&2
  exit 1
fi
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
configuration="${CONFIGURATION:-debug}"
swift build -c "$configuration" --cache-path "$PWD/.build/cache" --disable-sandbox
bin="$(swift build -c "$configuration" --cache-path "$PWD/.build/cache" --disable-sandbox --show-bin-path)"
app="$PWD/build/Live2D Avatar.app"
if [[ -n "${PRIVATE_ASSETS_DIR:-}" ]]; then
  app="$PWD/build/Live2D Avatar Private.app"
  for model in live2d_model live2d_model_creature; do
    if [[ ! -d "$PRIVATE_ASSETS_DIR/$model" ]]; then
      echo "Missing private model: $PRIVATE_ASSETS_DIR/$model" >&2
      exit 1
    fi
  done
fi
mkdir -p "$app/Contents/MacOS"
# Always rebuild resources so an earlier custom/private model cannot leak into this bundle.
rm -rf "$app/Contents/Resources"
mkdir -p "$app/Contents/Resources/Shaders" "$app/Contents/Resources/Licenses" "$app/Contents/Frameworks"
cp "$bin/Live2DAvatar" "$app/Contents/MacOS/Live2DAvatar"
cp App/Info.plist "$app/Contents/Info.plist"
cp App/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
framework="$PWD/.build/artifacts/webrtc/WebRTC/WebRTC.xcframework/macos-x86_64_arm64/WebRTC.framework"
ditto "$framework" "$app/Contents/Frameworks/WebRTC.framework"
cp .build/checkouts/WebRTC/LICENSE.md "$app/Contents/Resources/Licenses/WebRTC-LICENSE.md"
cp .build/checkouts/Yams/LICENSE "$app/Contents/Resources/Licenses/Yams-LICENSE"
cp LICENSE THIRD_PARTY_NOTICES.md "$app/Contents/Resources/Licenses/"
cp vendor/swift-cubism/LICENSE "$app/Contents/Resources/Licenses/swift-cubism-LICENSE"
cp vendor/swift-cubism/Core/*.md "$app/Contents/Resources/Licenses/"
cp vendor/swift-cubism/Sources/CubismFramework/LICENSE.md "$app/Contents/Resources/Licenses/CubismFramework-LICENSE.md"
cp local-assets/Haru/LICENSES.md "$app/Contents/Resources/Licenses/Haru-LICENSES.md"
codesign --force --sign - "$app/Contents/Frameworks/WebRTC.framework"
cp vendor/swift-cubism/Sources/CubismFramework/src/Rendering/Metal/MetalShaders.metal "$app/Contents/Resources/Shaders/"
cp vendor/swift-cubism/Sources/CubismFramework/src/Rendering/Metal/MetalShaderTypes.h "$app/Contents/Resources/Shaders/"
python3 scripts/prepare-model.py local-assets/Haru "$app/Contents/Resources/Haru"
if [[ -n "${PRIVATE_ASSETS_DIR:-}" ]]; then
  for model in live2d_model live2d_model_creature; do
    python3 scripts/prepare-model.py "$PRIVATE_ASSETS_DIR/$model" "$app/Contents/Resources/$model"
  done
  printf '%s\n' 'Personal build containing private model assets. Do not redistribute.' > "$app/Contents/Resources/PRIVATE_ASSETS.txt"
fi
# User profiles are local-only. Even a public profile is never bundled by this script.
codesign --force --deep --sign - "$app"
echo "$app"
