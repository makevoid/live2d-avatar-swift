# Swift Cubism bridge and downloaded SDK: macOS port

Upstream: https://github.com/nslogmeng/swift-cubism

Commit: `bd5413aa94468f79e9348b4f6fe7a1c356436dd8` (main at vendoring time).
Downloaded from GitHub's source archive because SSH was unavailable in the build
sandbox. Original archive SHA-256:
`a3749a255562f5bfbcc0d2415b9eb692b4304c7e0e24c63322326115de819f37`.
Only the MIT Swift/Objective-C++ bridge, package manifest and its license are
retained in source. Cubism Framework, Core and all model assets are installed
locally by `scripts/setup.py` and excluded from the source archive. No nested Git
repository is needed. The Framework changes are reproduced by the 112-line
`scripts/patches/cubism-metal-macos.patch`, under the original Live2D terms.

## Core binary

The setup task creates a macOS-only `macos-arm64_x86_64` XCFramework slice
from the official **Cubism SDK for Native 5-r.4.1**, matching the bundled
Framework version. The ARM64 and x86_64 static libraries were combined with `lipo`.
Both architectures are present in Core; this app was built and tested on ARM64.

Source: https://cubism.live2d.com/sdk-native/bin/CubismSdkForNative-5-r.4.1.zip

SDK archive SHA-256:
`b71ec6bafc6578cce3b4cbbaa42a1cb51ae6eb477557932b02d22af957e733c7`.

Core license and SDK notices are installed in the ignored `Core/` folder. Core is proprietary Live2D software;
the wrapper's MIT license does not replace Core's or Framework's licenses.

## Local changes

- Package: add public Objective-C umbrella header and Swift re-export, compile
  the bridge with ARC and framework without ARC, link libc++ and macOS frameworks,
  remove the incorrect dynamic Core framework link, exclude the unused legacy
  `UserModel.mm` and Metal source from C++ compilation, remove unsupported watchOS.
- Metal platform: replace UIKit import with Foundation/QuartzCore and accept an
  injected shader library. The app compiles the supplied shader source at runtime.
- Skip zero-length buffers for empty meshes, which otherwise fail Metal API validation.
- Add per-drawable visibility overrides in the Metal renderer, exposed to Swift,
  for hiding accessories without editing model assets or fighting expressions.
- Texture loading: ImageIO/CoreGraphics on macOS and iOS, premultiplied RGBA,
  one fully initialized mip level, explicit shader-read usage and shared storage.
- File loading: fix shadowed NSData, initialize sizes on failure, handle missing
  model data, normalize folder separators, check the correct MOC path, and avoid
  treating log strings as format strings.
- Model lifecycle: guard cleanup after partial initialization, stop motion
  managers before deleting their motions, require every texture, validate MOC3.
- Swift-facing render method, actual frame delta, smooth cursor inputs, mouth
  control, pose reset, parameter/drawable counts, and parameter value access.
- Add a validated parameter setter that saves the base pose, allowing avatars to
  start smiling before their first frame without advancing the animation clock.
- Expose the compiled rig's parameter minimum, maximum and default values for
  model-specific expressive animation. Add a transient emotion layer with
  absolute values, additive gestures and multiplicative eyelid factors after
  breathing/mouth input and before physics. Reject nonexistent parameter IDs
  and nonfinite values; use Cubism's range clamping. Do not save these overlays
  into base parameters, so clearing emotions preserves authored motion state.
- Correct premultiplied alpha flag and force motion priority; reject invalid
  motion indices and failed motion loads.

The host serializes GPU frames because this renderer updates shared vertex
buffers in place. Concurrent models or renderers require additional coordination:
the Cubism framework and Metal renderer maintain process-wide state.
