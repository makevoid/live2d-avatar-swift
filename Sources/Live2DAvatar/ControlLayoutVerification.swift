import AppKit
import AvatarBehavior
import GPTLiveSwift

/// Check the floating bar, panels and chip routing, and capture the window as it is composited:
/// the GPU avatar under the AppKit overlays.
@MainActor
func verifyControlLayout(controller: AppDelegate, output: URL) throws -> [String: Any] {
    let folder = output.appendingPathComponent("controls", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let window = controller.window!, content = window.contentView!
    let originalAvatar = controller.renderer.avatar
    let originalName = originalAvatar?.persona.name.lowercased() ?? "custom"
    // A custom --model is verified in place; bundled builds exercise only installed models.
    let avatars: [BundledAvatar?] = originalAvatar == nil ? [nil] : controller.availableAvatars.map { $0 }
    func capture(_ view: NSView) -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }
    // NSImageRep.draw(in:) copies pixels; overlays are translucent and must blend over the avatar.
    func composite(_ view: NSView, in frame: NSRect) {
        capture(view).draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
    func panelView(_ button: NSButton) -> NSView {
        let view = controller.panels[button]!.contentViewController!.view
        view.layoutSubtreeIfNeeded()
        view.setFrameSize(view.fittingSize)
        view.layoutSubtreeIfNeeded()
        return view
    }
    func drawPanel(_ view: NSView, in frame: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
        shadow.shadowBlurRadius = 14
        shadow.set()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: frame, xRadius: 12, yRadius: 12).fill()
        NSGraphicsContext.restoreGraphicsState()
        composite(view, in: frame)
    }
    func overview(_ name: String, opening button: NSButton? = nil, backdrop: Bool = true) throws {
        content.layoutSubtreeIfNeeded()
        let size = content.bounds.size, width = Int(size.width) * 2, height = Int(size.height) * 2
        let avatar = try controller.renderer.image(controller.renderer.snapshot(width: width, height: height),
                                                   width: width, height: height)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        if !backdrop {
            // Leave the canvas clear: what the floating window actually puts on the desktop.
        } else if controller.renderer.transparent {
            // Stand-in desktop wallpaper shows that only the avatar and controls are opaque.
            NSGradient(starting: NSColor(calibratedRed: 0.22, green: 0.36, blue: 0.62, alpha: 1),
                       ending: NSColor(calibratedRed: 0.62, green: 0.42, blue: 0.66, alpha: 1))!
                .draw(in: NSRect(origin: .zero, size: size), angle: 60)
        } else {
            NSColor(calibratedRed: 0.93, green: 0.94, blue: 0.95, alpha: 1).setFill()
            NSRect(origin: .zero, size: size).fill()
        }
        NSGraphicsContext.current!.cgContext.draw(avatar, in: CGRect(origin: .zero, size: size))
        for view in [controller.statusView!, controller.captionsView!, controller.controlBar!, controller.miniBar!] where !view.isHidden {
            composite(view, in: view.frame)
        }
        if let button {
            let view = panelView(button)
            let anchor = button.convert(button.bounds, to: content)
            let x = min(max(12, anchor.midX - view.frame.width / 2), size.width - view.frame.width - 12)
            drawPanel(view, in: NSRect(origin: NSPoint(x: x, y: anchor.maxY + 18), size: view.frame.size))
        }
        NSGraphicsContext.restoreGraphicsState()
        try bitmap.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent(name))
    }

    // Everything must stay reachable at the minimum window size.
    let defaultSize = content.bounds.size
    window.setContentSize(window.contentMinSize)
    content.layoutSubtreeIfNeeded()
    guard content.bounds.contains(controller.controlBar.frame),
          !controller.controlBar.frame.intersects(controller.statusView.frame) else {
        throw ViewerError.message("The control bar does not fit the minimum window size.")
    }
    window.setContentSize(defaultSize)
    content.layoutSubtreeIfNeeded()
    let voiceFrame = controller.voiceButton.convert(controller.voiceButton.bounds, to: content)
    guard abs(voiceFrame.midX - controller.controlBar.frame.midX) < 1 else {
        throw ViewerError.message("The voice button is not centered in the control bar.")
    }

    var panelSizes: [String: String] = [:]
    for avatar in avatars {
        if let avatar { try controller.selectAvatar(avatar) }
        controller.reset()
        controller.automaticEmotion.state = avatar == nil ? .off : .on
        controller.toggleAutomaticEmotion()
        let name = avatar?.persona.name.lowercased() ?? "custom"
        guard controller.emotionChips.chips.count == AvatarEmotion.allCases.count,
              controller.expressionChips.chips.count == controller.expression.numberOfItems,
              controller.motionChips.chips.count == controller.motionItems.count,
              controller.emotionChips.chips.filter(\.isSelected).map(\.title) == (avatar == nil ? [] : ["Happy"]),
              controller.expressionChips.chips.filter(\.isSelected).map(\.title) == ["Neutral"] else {
            throw ViewerError.message("\(name) chip grids do not match the expression, motion and emotion models.")
        }
        for button in [controller.characterButton, controller.faceButton, controller.viewButton] {
            let view = panelView(button)
            // Panels open above the bar and must fit between it and the top of the default window.
            guard view.frame.height < defaultSize.height - controller.controlBar.frame.maxY else {
                throw ViewerError.message("The \(button.title) panel is taller than the space above the bar.")
            }
            panelSizes["\(name)-\(button.title.lowercased())"] = NSStringFromSize(view.frame.size)
        }
        try overview("ui-\(name).png")
        try overview("ui-\(name)-expressions.png", opening: controller.faceButton)

        // Chips route through the same actions as the models they display.
        let expressionIndex = controller.expression.numberOfItems > 1 ? 1 : 0
        controller.expressionChips.chips[expressionIndex].performClick(nil)
        guard controller.expression.indexOfSelectedItem == expressionIndex, controller.expressionChips.chips[expressionIndex].isSelected,
              controller.automaticEmotion.state == .off, controller.emotionChips.chips.allSatisfy({ !$0.isSelected }) else {
            throw ViewerError.message("An expression chip did not select its expression.")
        }
        if avatar != nil {
            controller.emotionChips.chips[AvatarEmotion.allCases.firstIndex(of: .curious)!].performClick(nil)
            guard controller.renderer.emotion == .curious, controller.emotionPicker.titleOfSelectedItem == "Curious",
                  controller.emotionChips.chips.filter(\.isSelected).map(\.title) == ["Curious"] else {
                throw ViewerError.message("An emotion chip did not apply its emotion.")
            }
        } else if controller.emotionChips.chips.contains(where: \.isEnabled) {
            throw ViewerError.message("A custom model enabled emotions without a configured persona.")
        }
        controller.pause.state = .on
        controller.togglePause(controller.pause)
        guard controller.renderer.paused else {
            throw ViewerError.message("The pause switch did not pause animation.")
        }
        if !controller.motionItems.isEmpty {
            let motion = controller.motions.itemTitles.firstIndex(of: "Sad") ?? 0
            controller.motionChips.chips[motion].performClick(nil)
            guard !controller.renderer.paused, controller.pause.state == .off,
                  controller.motions.indexOfSelectedItem == motion, controller.motionChips.chips[motion].isSelected else {
                throw ViewerError.message("A motion chip did not play its motion and resume animation.")
            }
        }
        controller.pause.state = .off
        controller.togglePause(controller.pause)
        controller.reset()
    }

    if let originalAvatar { try controller.selectAvatar(originalAvatar) }
    controller.automaticEmotion.state = originalAvatar == nil ? .off : .on
    controller.toggleAutomaticEmotion()
    try overview("ui-\(originalName).png")
    try Data(contentsOf: folder.appendingPathComponent("ui-\(originalName).png"))
        .write(to: output.appendingPathComponent("app-window.png"))
    for (name, button) in [("character", controller.characterButton), ("expressions", controller.faceButton),
                           ("view", controller.viewButton)] {
        let view = panelView(button)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.frame.width + 40) * 2,
            pixelsHigh: Int(view.frame.height + 40) * 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = NSSize(width: view.frame.width + 40, height: view.frame.height + 40)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor(calibratedWhite: 0.93, alpha: 1).setFill()
        NSRect(origin: .zero, size: bitmap.size).fill()
        drawPanel(view, in: NSRect(x: 20, y: 20, width: view.frame.width, height: view.frame.height))
        NSGraphicsContext.restoreGraphicsState()
        try bitmap.representation(using: .png, properties: [:])?
            .write(to: folder.appendingPathComponent("panel-\(name).png"))
    }
    try capture(controller.controlBar).representation(using: .png, properties: [:])?
        .write(to: folder.appendingPathComponent("control-bar.png"))
    try capture(controller.controlBar).representation(using: .png, properties: [:])?
        .write(to: output.appendingPathComponent("controls.png"))

    // Live voice: mute becomes available and captions float above the bar.
    controller.captionText.removeAll()
    controller.userCaption.stringValue = ""; controller.assistantCaption.stringValue = ""
    controller.refreshVoiceControls(.connected)
    guard controller.muteButton.isEnabled, controller.voiceButton.isActive, controller.voiceButton.title == "Cancel voice",
          !controller.captionsView.isHidden else {
        throw ViewerError.message("Connected voice did not reveal mute and captions.")
    }
    try overview("ui-\(originalName)-voice-listening.png")
    controller.receiveTranscript(LiveTranscript(speaker: .user, delta: "Can you smile for me?",
                                                startMilliseconds: 0, endMilliseconds: 900))
    controller.receiveTranscript(LiveTranscript(speaker: .assistant, delta: "Of course! Here's my brightest smile.",
                                                startMilliseconds: 1000, endMilliseconds: 2600))
    content.layoutSubtreeIfNeeded()
    guard controller.captionHint.isHidden, content.bounds.contains(controller.captionsView.frame),
          !controller.captionsView.frame.intersects(controller.controlBar.frame.insetBy(dx: 0, dy: FloatingSurface.shadowMargin)) else {
        throw ViewerError.message("Captions overlap the control bar.")
    }
    try overview("ui-\(originalName)-voice.png")
    controller.refreshVoiceControls(.closed)
    controller.userCaption.stringValue = ""; controller.assistantCaption.stringValue = ""
    controller.refreshCaptions()
    controller.clearChat()
    guard !controller.muteButton.isEnabled, !controller.voiceButton.isActive, controller.voiceButton.title == "Start voice",
          controller.captionsView.isHidden else {
        throw ViewerError.message("Stopping voice left live controls visible.")
    }

    // Desktop mode: no chrome, window background or scenery; a two-button pill replaces the bar; leaving restores everything.
    let titledFrame = window.frame
    for avatar in avatars {
        if let avatar { try controller.selectAvatar(avatar) }
        controller.setDesktopMode(true)
        let corner = try controller.renderer.snapshot(width: 32, height: 32)
        guard !window.styleMask.contains(.titled), !window.isOpaque, window.backgroundColor.alphaComponent == 0,
              !window.hasShadow, window.level == .floating, window.canBecomeKey, controller.metalView.movesWindow,
              controller.metalView.layer?.isOpaque == false, controller.desktopMenuItem.state == .on, corner[3] == 0 else {
            throw ViewerError.message("Desktop mode left chrome or background visible for \(avatar?.title ?? "custom model").")
        }
    }
    if let originalAvatar { try controller.selectAvatar(originalAvatar) }
    // Scrolling must not zoom the avatar inside the floating window.
    let zoom = controller.renderer.zoom
    if let scroll = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 40, wheel2: 0, wheel3: 0)
        .flatMap(NSEvent.init(cgEvent:)) {
        controller.metalView.scrollWheel(with: scroll)
    }
    guard controller.renderer.zoom == zoom else { throw ViewerError.message("Scrolling zoomed the avatar in desktop mode.") }
    content.layoutSubtreeIfNeeded()
    guard controller.controlBar.isHidden, controller.statusView.isHidden, !controller.miniBar.isHidden,
          content.bounds.contains(controller.miniBar.frame), controller.miniVoiceButton.action == #selector(AppDelegate.toggleVoice),
          controller.miniVoiceButton.symbol == "mic.fill" else {
        throw ViewerError.message("Desktop mode did not swap the control bar for the voice and window pill.")
    }
    try overview("ui-desktop-mode.png")
    try overview("ui-desktop-mode-alpha.png", backdrop: false)
    controller.refreshVoiceControls(.connected)
    guard controller.miniVoiceButton.symbol == "xmark", controller.miniVoiceButton.toolTip == "Cancel voice" else {
        throw ViewerError.message("The desktop voice button did not follow the voice session.")
    }
    controller.captionText.removeAll()
    controller.receiveTranscript(LiveTranscript(speaker: .assistant, delta: "I'm right here on your desktop.",
                                                startMilliseconds: 0, endMilliseconds: 1200))
    try overview("ui-desktop-mode-voice.png")
    try overview("ui-desktop-mode-voice-alpha.png", backdrop: false)
    controller.refreshVoiceControls(.closed)
    controller.userCaption.stringValue = ""; controller.assistantCaption.stringValue = ""
    controller.refreshCaptions()
    controller.clearChat()
    controller.showWindowButton.performClick(nil)
    guard window.styleMask.contains(.titled), window.isOpaque, window.hasShadow, window.level == .normal,
          !controller.metalView.movesWindow, !controller.metalView.mouseDownCanMoveWindow, !window.isMovableByWindowBackground,
          controller.desktopMode.state == .off, !controller.controlBar.isHidden,
          !controller.statusView.isHidden, controller.miniBar.isHidden,
          window.frame == titledFrame, !controller.renderer.transparent else {
        throw ViewerError.message("Leaving desktop mode did not restore the window.")
    }
    return ["minimumWindowFits": true, "chipsMatchModels": true, "chipsRouteActions": true,
            "motionResumesPause": true, "voiceCentered": true, "desktopMode": true, "voiceRevealsLiveControls": true, "panelSizes": panelSizes]
}

