import AppKit
import AvatarBehavior
import GPTLiveSwift

/// Offline verification for the downloadable sample and user-supplied runtime models.
@MainActor
func verifyPublicModel(renderer: AvatarRenderer, output: URL) throws {
    _ = NSApplication.shared
    let controller = AppDelegate()
    controller.renderer = renderer
    controller.buildWindow(show: false)
    controller.metalView.isPaused = true
    defer { controller.metalView.delegate = nil }
    renderer.paused = true
    let before = try renderer.snapshot()
    let visible = stride(from: 3, to: before.count, by: 4).filter { before[$0] > 20 }.count
    guard visible > 10_000 else { throw ViewerError.message("Model did not render visible geometry.") }
    try renderer.savePNG(before, to: output.appendingPathComponent("haru.png"))
    renderer.model.dragX = 0.8
    renderer.model.dragY = 0.3
    renderer.model.mouthOpen = 0.6
    for _ in 0..<90 { renderer.model.update(deltaTime: 1.0 / 60) }
    let after = try renderer.snapshot()
    guard before != after else { throw ViewerError.message("Animation did not change model pixels.") }
    try renderer.savePNG(after, to: output.appendingPathComponent("haru-speaking.png"))
    for expression in renderer.manifest.FileReferences.Expressions ?? [] {
        renderer.model.resetPose()
        renderer.model.setExpression(expression.Name)
        for _ in 0..<90 { renderer.model.update(deltaTime: 1.0 / 60) }
        _ = try renderer.snapshot()
    }
    struct Motion: Decodable { struct Meta: Decodable { let Duration: Double }; let Meta: Meta }
    var checkedMotions = 0
    for (group, motions) in renderer.manifest.FileReferences.Motions ?? [:] {
        for (index, motion) in motions.enumerated() {
            let document = try JSONDecoder().decode(Motion.self, from: Data(contentsOf: renderer.modelDirectory.appendingPathComponent(motion.File)))
            renderer.model.resetPose()
            guard renderer.model.startMotion(withGroup: group, index: index, priority: 3, finishedHandler: nil, beganHandler: nil) != -1 else {
                throw ViewerError.message("Could not start \(motion.File).")
            }
            for _ in 0..<Int(ceil((document.Meta.Duration + 0.5) * 60)) { renderer.model.update(deltaTime: 1.0 / 60) }
            _ = try renderer.snapshot()
            if renderer.avatar == .character, motion.File.hasSuffix("guan.motion3.json"),
               abs(renderer.model.parameterValue(for: "Param43")) > 0.001 {
                throw ViewerError.message("guan did not finish hiding the raised arm.")
            }
            // Authored motions may fade out or loop. Only generated Face motions promise held endpoints.
            if group == "Face" {
                let name = URL(fileURLWithPath: motion.File).deletingPathExtension().deletingPathExtension().lastPathComponent
                if let expected = ["Smile": 1.0, "Sad": -1.0, "Neutral mouth": 0.0][name],
                   abs(renderer.model.parameterValue(for: "ParamMouthForm") - expected) > 0.001 {
                    throw ViewerError.message("Generated \(name) mouth motion ended at \(renderer.model.parameterValue(for: "ParamMouthForm")); expected \(expected).")
                }
            }
            checkedMotions += 1
        }
    }
    controller.reset()
    controller.automaticEmotion.state = .on
    controller.applyEmotion(.happy)
    for _ in 0..<120 { renderer.updateAnimation(deltaTime: 1.0 / 60) }
    controller.window.contentView?.layoutSubtreeIfNeeded()
    if let sidebar = controller.window.contentView?.subviews.compactMap({ $0 as? NSScrollView }).first,
       let bitmap = sidebar.bitmapImageRepForCachingDisplay(in: sidebar.bounds) {
        sidebar.cacheDisplay(in: sidebar.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("controls.png"))
    }
    // AppKit view caching omits Metal layers. Capture both real rendering surfaces
    // at the same layout and composite the GPU readback into its actual view frame.
    if let content = controller.window.contentView,
       let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
        content.cacheDisplay(in: content.bounds, to: bitmap)
        let frame = controller.metalView.convert(controller.metalView.bounds, to: content)
        let renderURL = output.appendingPathComponent("avatar-view.png")
        let width = Int(frame.width * 2), height = Int(frame.height * 2)
        try renderer.savePNG(renderer.snapshot(width: width, height: height), to: renderURL, width: width, height: height)
        let capture = NSImage(size: content.bounds.size)
        capture.lockFocus()
        controller.window.backgroundColor.setFill()
        content.bounds.fill()
        bitmap.draw(in: content.bounds)
        NSColor(calibratedRed: 0.93, green: 0.94, blue: 0.95, alpha: 1).setFill()
        frame.fill()
        NSImage(contentsOf: renderURL)?.draw(in: frame)
        capture.unlockFocus()
        if let tiff = capture.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try png.write(to: output.appendingPathComponent("app-window.png"))
        }
    }
    var switchedModels: [String] = []
    if let original = renderer.avatar, controller.availableAvatars.contains(original) {
        for avatar in controller.availableAvatars {
            try controller.selectAvatar(avatar)
            let motionCount = (renderer.manifest.FileReferences.Motions ?? [:]).values.reduce(0) { $0 + $1.count }
            guard renderer.avatar == avatar,
                  controller.expression.numberOfItems == renderer.expressions.count + 1,
                  controller.motionItems.count == motionCount,
                  controller.avatarPicker.selectedSegment == controller.availableAvatars.firstIndex(of: avatar) else {
                throw ViewerError.message("Avatar switch did not refresh controls for \(avatar.modelName).")
            }
            try renderer.savePNG(renderer.snapshot(), to: output.appendingPathComponent("\(avatar.directoryName)-switched.png"))
            switchedModels.append(avatar.modelName)
        }
        try controller.selectAvatar(original)
    }
    var report: [String: Any] = ["status": "passed", "model": renderer.modelName,
        "visiblePixels": visible, "animationChangesPixels": true, "motions": checkedMotions,
        "expressions": renderer.expressions.count, "device": renderer.device.name,
        "switchedModels": switchedModels]
    if let persona = renderer.avatar?.persona {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        controller.memoryDirectory = directory
        let store = try controller.memoryStore()
        let correction = "The user works at Harbor Studio, not directly for ClientCo."
        try store.remember(correction)
        try Data("The user's employer is ClientCo.".utf8).write(to: directory.appendingPathComponent("mem_private.md"))
        controller.memorySeed = try AvatarMemorySeed.load(directory: directory)
        func check(_ configuration: LiveConfiguration, has fact: String) throws {
            guard configuration.instructions.contains(fact), configuration.responses?.instructions.contains(fact) == true,
                  configuration.instructions.contains("Saved corrections override conflicting reference profile facts") else {
                throw ViewerError.message("Saved corrections missing from session context.")
            }
        }
        try check(controller.makeVoiceConfiguration(), has: correction)
        controller.memories = [:]
        try check(controller.makeVoiceConfiguration(), has: correction)
        let diskStore = try AvatarMemory(persona: persona, directory: directory)
        try diskStore.remember("Synthetic later saved fact.")
        try check(controller.makeVoiceConfiguration(), has: "Synthetic later saved fact.")
        try controller.memoryStore().clear()
        let cleared = try controller.makeVoiceConfiguration()
        guard !cleared.instructions.contains(correction), cleared.responses?.instructions.contains(correction) == false else {
            throw ViewerError.message("Deleted memory reappeared on restart.")
        }
        try Data("entries: [".utf8).write(to: store.url)
        var rejected = false
        do { _ = try controller.makeVoiceConfiguration() } catch { rejected = true }
        guard rejected else { throw ViewerError.message("Unreadable memories did not block Start.") }
        report["memoryRecall"] = ["restart": true, "diskReload": true, "correctionPrecedence": true, "clear": true, "corruption": true]
    }
    let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    try json.write(to: output.appendingPathComponent("result.json"))
    print(String(decoding: json, as: UTF8.self))
}
