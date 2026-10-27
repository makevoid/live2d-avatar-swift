# Installation and dependency setup

The project targets macOS 14+, Swift 6.1+ and Python 3. A Metal-capable Mac is
required to run the app or GPU tests. Install Xcode command-line tools with
`xcode-select --install`; a full compatible Xcode installation also works.

## One-time setup

Download the official `CubismSdkForNative-5-r.4.1.zip` after reviewing Live2D's terms,
then run:

```sh
python3 scripts/setup.py --sdk-zip ~/Downloads/CubismSdkForNative-5-r.4.1.zip
./scripts/run.sh
```

Alternatively, `python3 scripts/setup.py --download --accept-live2d-licenses`
downloads the same archive after your explicit acceptance. This switch is an
acknowledgment by the person running setup; the project does not accept licenses
on anyone's behalf.

Pinned archive:

- Source: <https://cubism.live2d.com/sdk-native/bin/CubismSdkForNative-5-r.4.1.zip>
- SHA-256: `b71ec6bafc6578cce3b4cbbaa42a1cb51ae6eb477557932b02d22af957e733c7`
- Framework: the version in that SDK, plus `scripts/patches/cubism-metal-macos.patch`.
- Core: official macOS ARM64 and x86_64 static libraries combined with `lipo`.
- Default model: `Samples/Resources/Haru`; prerecorded sounds and their manifest
  references are excluded because the app does not use them.

Setup validates the ZIP before installing. Repeating it replaces only the generated
SDK directories and `local-assets/Haru`; put custom models under another directory.
Do not make source edits inside generated SDK directories: record changes as patches.

## Local directory map

| Path | Contents | In source release? |
| --- | --- | --- |
| `vendor/swift-cubism/Sources/Cubism/` | Swift exports | Yes |
| `vendor/swift-cubism/Sources/CubismBridge/` | Objective-C++ bridge | Yes |
| `scripts/patches/` | Small macOS adaptation patch | Yes, with Live2D terms |
| `vendor/swift-cubism/Sources/CubismFramework/` | Downloaded/patched Framework | No |
| `vendor/swift-cubism/Core/` | Downloaded Core and notices | No |
| `local-assets/Haru/` | Downloaded default model | No |
| `.build/` | SwiftPM dependency/build cache | No |
| `build/` | Local app, checks and source archive | No |
| `memory_data/mem_private.md` | Optional personal reference profile | No |

The build bundles Haru, Metal shader source, required native libraries and license
notices. It never bundles user profiles or saved memory files. The renderer compiles
the shaders locally; a separately downloaded Metal compiler is not required.

## Troubleshooting

**Missing Core XCFramework / missing Haru:** run setup before opening Package.swift
in Xcode or invoking SwiftPM. SDK downloads are deliberately not triggered by build.

**Checksum mismatch:** use the exact pinned archive. A newer SDK may change binary
interfaces, shaders and model behavior. Do not bypass verification; update the pin,
patch and tests together when upgrading.

**No Metal device:** run the GPU test in a normal logged-in macOS desktop session.
Restricted automation sandboxes and some remote environments do not expose the GPU.
Offline Swift tests still work without a Metal device.

**SwiftPM download failed:** the first build needs access to GitHub for pinned Yams
and WebRTC packages and the WebRTC binary artifact. Retry after restoring access.

**Microphone / API errors:** see [voice setup](voice.md). Rendering works without
microphone permission or API access.

**Gatekeeper / sharing:** the locally built app is ad-hoc signed, not notarized.
A public binary release is a separate packaging, signing and licensing step; this
source preparation does not produce a redistributable, notarized release.
