<p align="center">
  <img src="https://github.com/user-attachments/assets/21f560c2-8363-4061-986a-7a6d3fb3e62e" width="128" alt="Live2D Avatar app icon">
</p>

<h1 align="center">Live2D Avatar for macOS</h1>

<p align="center">
  A native Swift companion with a Live2D avatar, Metal rendering, optional voice
  conversation, and persistent character memory.<br>
  No browser renderer or separate application server is required.
</p>

<p align="center">
  <a href="#quick-start">Quick start</a> ·
  <a href="#controls">Controls</a> ·
  <a href="#desktop-mode">Desktop mode</a> ·
  <a href="#optional-voice-and-chat">Voice &amp; chat</a> ·
  <a href="#memory-that-survives-sessions">Memory</a> ·
  <a href="#use-your-own-model">Your own model</a> ·
  <a href="doc/architecture.md">Architecture</a>
</p>

<p align="center">
  <img src="https://github.com/user-attachments/assets/9d2efc61-01eb-4239-82c2-cbefaebde51a" alt="Rei floating over a macOS desktop in desktop mode, next to a browser and a terminal, with a voice caption and the two-button voice pill" width="900">
</p>

<p align="center"><sub>
  Desktop mode: the window frame and background disappear and the character floats over your other apps.
  The desktop behind her is an illustration; the character, caption and controls are captured from the app.
</sub></p>

## What you can do

- **Animate locally** with blinking, breathing, physics, expressions and motions.
- **Frame the character**: drag to reposition, scroll to zoom, and optionally let
  the character follow the pointer.
- **Float on the desktop**: desktop mode hides the window frame and background and
  keeps the character on top of your other apps.
- **Talk by voice** through native WebRTC; the assistant's received audio drives
  mouth opening.
- **Read along** in a separate chat window with captions and clickable web-search sources.
- **Remember facts** for each character. New sessions load them automatically;
  saved corrections take precedence over older reference profiles.
- **Bring your own model**: load another creator's Cubism runtime model from a local directory.

Rendering and manual controls work without an API key. Voice, web search and
semantic emotion decisions are optional online features. Camera tracking and
phoneme-level lip sync are not implemented.

## Quick start

Requires macOS 14+, a Metal-capable Mac, Swift 6.1+ and Python 3
([full requirements](#requirements)). Review the
[SDK download terms](https://www.live2d.com/en/sdk/download/native/) and
[Haru sample terms](https://www.live2d.com/en/learn/sample/haru/) first.

```sh
git clone https://github.com/makevoid/live2d-avatar-swift.git
cd live2d-avatar-swift
python3 scripts/setup.py --download --accept-live2d-licenses   # SDK + Haru, pinned and verified
./scripts/run.sh                                               # build and open the app
```

Prefer to download the SDK yourself? See [Install and run](#install-and-run).

## Character gallery

Haru is the standard build. The app has also been tested with premium third-party
models, from human characters to creatures: Rei and Poldo below are animated with
the same rigs, expressions, motions and controls.

<table>
  <tr>
    <td width="33%" align="center">
      <img src="https://github.com/user-attachments/assets/41a6d68a-bbe7-4ed3-883a-02ace4b3101f" alt="Haru in the app window with the floating control bar"><br>
      <b>Haru</b> · standard build<br>
      <sub>© Live2D Inc.; <a href="https://www.live2d.com/en/learn/sample/haru/">sample's separate terms</a></sub>
    </td>
    <td width="33%" align="center">
      <img src="https://github.com/user-attachments/assets/a00165df-8cea-4ddf-88cd-435dfab59315" alt="Rei in the app window with the floating control bar"><br>
      <b>Rei</b> · personal build default<br>
      <sub><b>Bear Commander</b> by <b>DG_STUDIO / @KenKenMo6 / 天才设计学家</b></sub>
    </td>
    <td width="33%" align="center">
      <img src="https://github.com/user-attachments/assets/aab2aca3-dd51-42ff-8a51-2172a1a89744" alt="Poldo in the app window with the mountain meadow and the floating control bar"><br>
      <b>Poldo</b> · creature<br>
      <sub><b>F2U Red Panda</b> model; the meadow is drawn by the app</sub>
    </td>
  </tr>
</table>

Rei and Poldo remain optional models. Their model files are not included or
downloaded by normal setup; **Haru remains the standard build's default**. Other
characters may need their own configuration; see the [model guide](doc/models.md).
Model artwork and screenshots retain their creators' rights and are not covered
by the app's MIT license.

## What is in this repository?

**Application and Swift/Objective-C++ glue source: yes. Live2D SDK and model files: no.**

Setup obtains the official **Cubism SDK for Native 5-r.4.1** and its **Haru** sample
into ignored local folders. Build then embeds the required runtime files in your
local `.app`. The source export contains no Cubism Core binaries/headers, Framework
source tree, model textures, `.moc3` files, purchased models, or private memories.

Our code is [MIT licensed](LICENSE). Live2D's runtime and sample artwork have
[separate terms](THIRD_PARTY_NOTICES.md); the complete runtime is not MIT licensed.

## Requirements

- macOS 14 or newer and a Metal-capable Mac.
- Swift 6.1 or newer. Install Apple's Xcode command-line tools or a compatible Xcode.
- Python 3, Git, and Apple's `xcrun`, `lipo`, `codesign` and `ditto` tools.
- Internet access for the initial SDK download and pinned SwiftPM dependencies.
- Optional: an OpenAI API project with access to the configured voice and backend models.

Check your tools:

```sh
xcode-select --install   # only if command-line tools are not installed
swift --version
python3 --version
xcrun --find lipo
```

Apple Silicon is the tested platform. Setup creates a Core library containing both
ARM64 and x86_64; Intel execution has not been verified here.

## Install and run

Start in the extracted source folder or clone this clean application repository:

```sh
git clone https://github.com/makevoid/live2d-avatar-swift.git
cd live2d-avatar-swift
```

### 1. Obtain the SDK and default model

Review the [SDK download terms](https://www.live2d.com/en/sdk/download/native/),
[Haru sample terms](https://www.live2d.com/en/learn/sample/haru/), and
[third-party notices](THIRD_PARTY_NOTICES.md).

**Manual download:** download `CubismSdkForNative-5-r.4.1.zip` from Live2D's
[official versioned archive](https://cubism.live2d.com/sdk-native/bin/CubismSdkForNative-5-r.4.1.zip),
then import it:

```sh
python3 scripts/setup.py --sdk-zip ~/Downloads/CubismSdkForNative-5-r.4.1.zip
```

**Setup download:** after reviewing and accepting the separate Live2D terms:

```sh
python3 scripts/setup.py --download --accept-live2d-licenses
```

Both routes verify the archive's pinned SHA-256, apply the small macOS Metal patch,
prepare the macOS Core slice, and install Haru. They do not download executable
installers or add model/SDK files to Git. Haru's prerecorded voice is excluded.
See [installation details](doc/installation.md) for paths and troubleshooting.

### 2. Build and open

```sh
./scripts/run.sh
```

The first build downloads WebRTC and Yams through SwiftPM. The result is
`build/Live2D Avatar.app`, locally ad-hoc signed. Double-click it in Finder on
subsequent launches. It is not notarized.

```sh
./scripts/build.sh                          # build without opening
CONFIGURATION=release ./scripts/build.sh    # optimized local build
./scripts/test.sh                           # offline tests + real GPU check
```

`rake` and `rake run` are optional shortcuts if Ruby/Rake is installed. To work in
Xcode, run setup and build once, then open `Package.swift`.

## Controls

The avatar fills the window. One floating bar holds everything: panels on the left,
voice in the middle, conversation on the right.

<p align="center">
  <img src="https://github.com/user-attachments/assets/3049ccfa-8f3f-4995-90b6-59af673d4ff7" alt="Rei with the Expressions panel open above the control bar: emotion, expression and motion chips and the mouth slider" width="760">
</p>

| Control | Behavior |
| --- | --- |
| Character (shows the current name) | Switch character; model stats and credits |
| Expressions | Emotion, expression and motion chips, Automatic emotions, mouth opening |
| View | Follow mouse, pause animation, desktop mode, reset pose & view |
| **Start voice** / **Cancel voice** | Start or end a voice session |
| Mute | Mute the microphone while staying connected |
| Chat / ⌘⇧C | Open or hide the separate conversation window |
| Memory | Inspect or clear facts saved for the current character |
| Drag / scroll on the avatar | Reposition / zoom |

Haru is the default. Only models actually bundled in the app appear in its selector.
The available expressions and motions come from the model manifest. Manual pose
changes turn off automatic emotions so the selected look can hold.

## Desktop mode

Turn on **Desktop mode** in the View panel (or press ⇧⌘D). The window frame, shadow
and background disappear, scenery is hidden, and the character stays on top of other
windows. A small pill keeps two buttons: start or cancel voice, and bring the full
window back (Esc does the same). Dragging moves the window rather than the character
inside it, and scrolling does not zoom.

## Optional voice and chat

The current client uses `gpt-live-1` for native WebRTC voice and `gpt-6-luna` for
Responses delegation and emotion decisions. Your API project must have access to
these models; an API key alone does not guarantee availability. The renderer does
not depend on those services.

Supply `OPENAI_API_KEY` when launching the executable from a shell, or put only the
key in `~/.openai_api_key` for Finder launches. Restrict that file to your account:

```sh
chmod 600 ~/.openai_api_key
```

Never commit credentials. Click **Start voice**, allow microphone access, and speak.
Try “smile”, “pause animation”, or “remember that I prefer Swift”. Memory changes
show the exact fact and character for confirmation. **Mute** keeps the
session connected; **Cancel voice** ends it. API usage is billed to your OpenAI project.

Set `OPENAI_VOICE_BACKEND_MODEL` to override the backend with a compatible model.
See [voice and privacy](doc/voice.md) for credential handling, data flow and limitations.

## Memory that survives sessions

Explicit facts live in `~/Library/Application Support/Live2DAvatar/haru.yaml`
(and separate files for other configured characters). They are local, unencrypted,
owner-readable YAML. Each voice Start reloads them into both voice and backend
context; confirmed changes refresh recall during the session.

The app optionally reads `memory_data/mem_private.md`, falling back to
`mem_public.md` in the source checkout. Neither is bundled by the build script.
No user identity or biography is assumed by default. Facts follow this precedence:

1. Your latest direct correction in the conversation.
2. The current character's saved corrections, newest first in priority.
3. The selected reference profile.
4. Public or web information.

A read-only profile cannot override a saved correction. **Clear chat** only clears
the display. **Forget all** clears saved facts for that character, not the profile
or the model's existing conversation context. Restart voice to clear that context.
More details: [memory and delegation](doc/delegation.md).

## Use your own model

Obtain a Cubism **runtime export** you are permitted to use: one `.model3.json`,
its `.moc3`, textures, and referenced physics, expressions and motions. An editor
project (`.cmo3`) or a VTube Studio settings file alone is not enough.

```sh
mkdir -p local-assets/custom
python3 scripts/prepare-model.py "/path/to/MyModel/runtime" "local-assets/custom/MyModel"
"build/Live2D Avatar.app/Contents/MacOS/Live2DAvatar" \
  --model "$PWD/local-assets/custom/MyModel"
```

The app loads that model locally; it does not upload its files. See the
[complete model guide](doc/models.md) for folder structure, expressions, limits,
adding a persona and memory, and bundling another model intentionally.

## Optional personal asset collection

Owners of a separate private asset repository can load the Rei/Poldo integration
with one task after normal SDK setup:

```sh
PRIVATE_ASSETS_REPO=git@github.com:YOUR_ACCOUNT/YOUR_PRIVATE_ASSETS.git rake private
```

This clones into ignored `local-assets/private/`, validates both models, links local
reference profiles, and opens `build/Live2D Avatar Private.app` with Rei selected.
Later, `rake private`
reuses that checkout. Git authentication must already grant access to the private repo.
The ordinary build still produces the Haru app. Neither build bundles profiles, and
source packaging excludes the private checkout. See the [private setup guide](doc/private-assets.md)
for the layout, updates, and a command that does not require Rake.

## Verification and contributing

`./scripts/test.sh` runs the offline Swift suite and a Metal smoke test. It checks
visible rendering, changed animation pixels, all Haru expressions and full motion
durations, generated mouth-pose endpoints, and saved-memory recall across restarts.
Results and PNGs appear in `build/verification/`. No microphone or API calls are
needed. Opt-in live API tests are separate and billed.

The app has three main layers:

- `Sources/Live2DAvatar/`: AppKit UI, Metal rendering, model loading and GPU checks.
- `Sources/AvatarBehavior/`: personas, emotions, transcripts and persistent memory.
- `Sources/GPTLiveSwift/`: native WebRTC, session lifecycle and Responses delegation.

`vendor/swift-cubism/` retains the MIT bridge. Setup installs the separately licensed
Framework and Core beside it. [Architecture](doc/architecture.md),
[bridge changes](vendor/swift-cubism/LOCAL_CHANGES.md), and [AGENTS.md](AGENTS.md)
describe the development boundaries.

Before sharing source, run:

```sh
python3 scripts/package-source.py
```

This creates an audited source-only ZIP under `build/`. It excludes downloaded SDKs,
models, bundles, credentials, profiles and Git history even after a local build.
Do not upload the whole working directory or your locally built app as source.

## Credits and release terms

Built on [nslogmeng/swift-cubism](https://github.com/nslogmeng/swift-cubism),
[Live2D Cubism](https://www.live2d.com/en/sdk/about/),
[stasel/WebRTC](https://github.com/stasel/WebRTC), and [Yams](https://github.com/jpsim/Yams).
Haru is © Live2D Inc., downloaded from the official SDK.

Publishing application source does not grant redistribution rights for SDKs or
models. Before releasing a compiled app, review Live2D's
[SDK release-license requirements](https://www.live2d.com/en/sdk/license/), including
its rules for applications that load user-supplied models, and the model creator's
terms. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
