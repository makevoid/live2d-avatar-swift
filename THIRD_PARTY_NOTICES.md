# Third-party components and assets

The application code is MIT licensed. That license does **not** cover the Live2D
SDK, sample artwork, model data or screenshots depicting that artwork.

| Component | Source and terms | How obtained |
| --- | --- | --- |
| Swift/Objective-C++ Cubism bridge | [nslogmeng/swift-cubism](https://github.com/nslogmeng/swift-cubism), MIT; original notice in `vendor/swift-cubism/LICENSE` | Source retained with local changes |
| Cubism Native Framework | [Live2D](https://github.com/Live2D/CubismNativeFramework), [Live2D Open Software License](https://www.live2d.com/eula/live2d-open-software-license-agreement_en.html) | Downloaded by setup; not in source export |
| Cubism Core | [Official Native SDK](https://www.live2d.com/en/sdk/download/native/), [Live2D Proprietary Software License](https://www.live2d.com/eula/live2d-proprietary-software-license-agreement_en.html) | Downloaded by setup; not in source export |
| Haru model and screenshot artwork | © Live2D Inc.; [Haru terms](https://www.live2d.com/en/learn/sample/haru/) and [Free Material License](https://www.live2d.com/eula/live2d-free-material-license-agreement_en.html) | Downloaded with SDK; only rendered previews are included in documentation |
| Rei screenshot | Bear Commander model by DG_STUDIO / @KenKenMo6 / 天才设计学家; creator's separate terms, not MIT | Rendered documentation image only; model files are excluded |
| Poldo screenshot | F2U Red Panda model; artwork retains its creator's rights, not MIT | Rendered documentation image only; model files are excluded |
| WebRTC | [stasel/WebRTC](https://github.com/stasel/WebRTC), BSD license | Pinned SwiftPM dependency; notice copied into local app |
| Yams | [jpsim/Yams](https://github.com/jpsim/Yams), MIT | Pinned SwiftPM dependency; notice copied into local app |

The small patch in `scripts/patches/` modifies the downloaded Framework and
retains its Live2D licensing; it is not a relicensing of SDK code under MIT.
Haru's prerecorded voice files are excluded and are not played by this application.

This repository distributes source for the application and bridge, not a Live2D
SDK distribution or a prebuilt app. A locally built app contains Core and the Haru
runtime model. Review the [SDK release-license requirements](https://www.live2d.com/en/sdk/license/)
and sample terms before publishing that app. Apps that load user-supplied models
may fall under Live2D's Expandable Applications rules; source publication does not
grant a release license for the resulting product.

Do not add purchased models, a user's model collection, private profiles,
recordings, API keys, SDK archives, or generated app bundles to a public release.
