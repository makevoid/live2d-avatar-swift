# Architecture

The app is a macOS AppKit executable. `AvatarRenderer` owns Cubism and Metal;
`main.swift` owns windows, controls, voice tasks and validated app tool actions.
The host serializes GPU frames because the renderer updates shared vertex buffers.
Only one model/renderer is active at a time; Cubism has process-wide state.

```text
AppKit controls ──► AvatarRenderer ──► Objective-C++ bridge ──► Cubism / Metal
       │                  ▲
       │                  │ local emotion and mouth parameters
       ▼                  │
GPTLiveClient ◄── WebRTC audio + transcript events ──► OpenAI voice session
       │
       └── Responses delegation ──► validated avatar / memory tools
```

`Sources/GPTLiveSwift/` contains transport, lifecycle, credential loading and native
Responses tool events. `Sources/AvatarBehavior/` contains identities, expression
catalogs, procedural emotion recipes, bounded transcript history and YAML memory.
Automatic emotions use transcript meaning; audio levels drive mouth opening.

Each frame restores model parameters, advances authored motions, saves the base,
then applies blinking, expressions, pointer input, breathing, mouth opening and
transient emotion overlays before physics and drawable updates. Emotion parameters
are limited to IDs/ranges in the compiled model. Overlays do not accumulate in the
saved base and do not own speech mouth opening.

The default Haru model is installed by setup, then copied/prepared into the local
bundle. Resources are not SwiftPM resources: run the build script before opening
Xcode. The build copies Metal shader source for local runtime compilation and
third-party license notices. It recreates the resource folder each time to prevent
stale custom model files from carrying into another bundle.

Swift and Objective-C++ bridge source remains in `vendor/swift-cubism`. Downloaded
Framework/Core folders are ignored and omitted from source packaging. A pinned
SDK archive and a small Framework patch reproduce the macOS integration; see
[installation](installation.md) and the bridge's `LOCAL_CHANGES.md`.

The code retains optional private-model descriptors, but no corresponding assets are distributed. The normal public GPU
path uses Haru. The selector lists only configured models present in the bundle.
An arbitrary `--model` directory loads with generic instructions; a named persona
and independent memory require an explicit catalog entry.
