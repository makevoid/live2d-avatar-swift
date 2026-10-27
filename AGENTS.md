# Repository guidelines

This is the clean public source tree. The application and Swift/Objective-C++ glue
are MIT licensed; downloaded Live2D SDK and sample assets retain separate terms.
Never commit SDK Core binaries/headers, Framework source, model runtime assets,
private profiles, user memories, credentials, build outputs or dependency caches.

Use `python3 scripts/setup.py --sdk-zip /path/to/CubismSdkForNative-5-r.4.1.zip`,
then `./scripts/build.sh`, `./scripts/run.sh`, or `./scripts/test.sh`.
The GPU checks require a normal macOS login session with Metal access.
Use four-space indentation in Swift and Python, keep rendering in AvatarRenderer,
UI in main.swift, and voice/session logic in GPTLiveSwift. Retain vendor licenses
and record bridge or SDK patch changes in vendor/swift-cubism/LOCAL_CHANGES.md.
See README.md and doc/models.md for the supported setup and model pipeline.

`rake private` is an optional personal workflow: it reads an authenticated checkout
under ignored `local-assets/private/` and produces `build/Live2D Avatar Private.app`.
Normal builds stay Haru-only. Never merge the old development history into this
repository. Keep asset/profile changes in the private assets repository, and run
the source export checks after changing either setup or packaging.
