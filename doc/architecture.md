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

The avatar fills the window under a floating control bar. UI components and actions
live in `main.swift`: the Character, Expressions and View popovers, expression and
motion chips, centered voice button, captions, chat and memory controls. Character
names come from the installed models' personas. Desktop mode removes the window
frame and background, hides scenery, and replaces the bar with voice and restore
buttons. `AvatarMetalView` moves the window on drag and disables zoom in that mode.
The Window menu provides ⇧⌘D for desktop mode and ⇧⌘C for chat; Esc restores the
full window. Space has no voice shortcut.

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
The normal bundle defaults to Haru; the personal build sets `Live2DDefaultModel`
to Rei in its generated Info.plist. Explicit `--model` arguments take precedence.
Haru and Rei use individual upper-body camera presets on load and Reset.
An arbitrary `--model` directory loads with generic instructions; a named persona
and independent memory require an explicit catalog entry.

`PublicModelVerification.swift` checks rendering, motions, switching and memory.
`ControlLayoutVerification.swift` checks the floating controls, chip actions,
caption layout and desktop-mode transitions using only the models in the bundle.
It composites GPU readback with AppKit overlays for the verification screenshots.
Both run offline through `./scripts/test.sh` with Haru; the personal app's
`--smoke-test` also exercises Rei and Poldo when installed.
