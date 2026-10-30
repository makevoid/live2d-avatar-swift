import AppKit
import Cubism
import MetalKit
import GPTLiveSwift
import AvatarBehavior

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextViewDelegate, NSPopoverDelegate {
    var window: NSWindow!
    var renderer: AvatarRenderer!
    var metalView: AvatarMetalView!
    // Off-screen selection models; the Expressions panel shows them as chip grids.
    let expression = ObservedPopUpButton()
    let motions = ObservedPopUpButton()
    let mouth = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    let availableAvatars = BundledAvatar.available(in: resourceDirectory())
    lazy var avatarPicker = NSSegmentedControl(labels: availableAvatars.map { $0.persona.name },
                                          trackingMode: .selectOne, target: nil, action: nil)
    let follow = NSSwitch()
    let pause = NSSwitch()
    let desktopMode = NSSwitch()
    var desktopMenuItem: NSMenuItem!
    let miniVoiceButton = MiniButton(symbol: "mic.fill", toolTip: "Start voice", fill: .controlAccentColor)
    let showWindowButton = MiniButton(symbol: "macwindow", toolTip: "Show window (Esc)")
    var miniBar: NSView!
    static let titledStyle: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    static let windowBackground = NSColor(calibratedWhite: 0.98, alpha: 1)
    static let avatarBackground = MTLClearColorMake(0.93, 0.94, 0.95, 1)
    let voiceButton = VoiceButton()
    let muteButton = BarButton(symbol: "mic.slash", title: "Mute", toolTip: "Mute microphone")
    let chatButton = BarButton(symbol: "bubble.left.and.bubble.right", title: "Chat", toolTip: "Show chat (⇧⌘C)")
    let memoryButton = BarButton(symbol: "brain.head.profile", title: "Memory",
                                 toolTip: "Saved memories · each character keeps their own")
    let characterButton = BarButton(symbol: "person.crop.circle", title: "Character", toolTip: "Choose character")
    let faceButton = BarButton(symbol: "face.smiling", title: "Expressions", toolTip: "Emotions, expressions and motions")
    let viewButton = BarButton(symbol: "slider.horizontal.3", title: "View", toolTip: "View options")
    var controlBar: NSView!
    var statusView: NSView!
    var captionsView: NSView!
    let statusDot = StatusDot()
    var panels: [NSButton: NSPopover] = [:]
    var emotionChips: ChipGrid!
    var expressionChips: ChipGrid!
    var motionChips: ChipGrid!
    var chatMenuItem: NSMenuItem!
    var chatWindow: NSWindow?
    var chatScroll: NSScrollView?
    var chatTextView: NSTextView?
    var chatStatus: NSTextField?
    var chatClearButton: NSButton?
    var chatLatestButton: NSButton?
    var chatTranscript = ConversationTranscript()
    var chatRenderTask: Task<Void, Never>?
    var chatNeedsRender = true
    var renderingChat = false
    let voiceStatus = NSTextField(wrappingLabelWithString: "Voice off")
    let userCaption = NSTextField(wrappingLabelWithString: "")
    let assistantCaption = NSTextField(wrappingLabelWithString: "")
    let captionHint = NSTextField(wrappingLabelWithString: "Listening… try “smile” or “pause animation”.")
    var voiceLive = false
    var lastPanelClose: (popover: NSPopover, time: CFTimeInterval)?
    let emotionPicker = ObservedPopUpButton()
    let automaticEmotion = NSSwitch()
    var emotionDirector: EmotionDirector?
    var transientVoiceExpression = false
    var voice: GPTLiveClient?
    var voiceTask: Task<Void, Never>?
    var memoryDirectory = AvatarMemory.defaultDirectory
    var memories: [AvatarPersona: AvatarMemory] = [:]
    var memorySeed: AvatarMemorySeed?
    var lastResponsesInstructions: String?
    var captionText: [LiveTranscript.Speaker: String] = [:]
    var speechMouth = 0.0
    var terminating = false
    var modelLabel: NSTextField!
    var modelStats: NSTextField!
    var modelCredits: NSTextField!
    var motionItems: [(group: String, index: Int)] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            renderer = try makeRenderer()
            buildWindow()
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let voice, voice.state == .connecting || voice.state == .connected || voice.state == .closing else { return .terminateNow }
        terminating = true
        emotionDirector?.cancel()
        voice.stop()
        // Let final usage drain before the process exits; stop has a bounded timeout.
        Task { @MainActor in
            while voice.state == .closing {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        voiceTask?.cancel()
        emotionDirector?.cancel()
        chatRenderTask?.cancel()
        metalView?.isPaused = true
        metalView?.delegate = nil
        renderer = nil
    }

    func label(_ text: String, size: CGFloat = 13, secondary: Bool = false) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: size, weight: size >= 20 ? .semibold : .regular)
        label.textColor = secondary ? .secondaryLabelColor : .labelColor
        return label
    }

    func buildWindow(show: Bool = true) {
        let menu = NSMenu()
        let item = NSMenuItem(); menu.addItem(item)
        let appMenu = NSMenu(); item.submenu = appMenu
        appMenu.addItem(withTitle: "Quit Live2D Avatar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: ""); menu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit"); editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: ""); menu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window"); windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(.separator())
        chatMenuItem = windowMenu.addItem(withTitle: "Show Chat", action: #selector(toggleChat), keyEquivalent: "c")
        chatMenuItem.keyEquivalentModifierMask = [.command, .shift]
        chatMenuItem.target = self
        desktopMenuItem = windowMenu.addItem(withTitle: "Desktop Mode", action: #selector(toggleDesktopMode(_:)), keyEquivalent: "d")
        desktopMenuItem.keyEquivalentModifierMask = [.command, .shift]
        desktopMenuItem.target = self
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = menu
        window = AvatarWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 860),
                              styleMask: Self.titledStyle, backing: .buffered, defer: false)
        window.contentMinSize = NSSize(width: 760, height: 640)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = Self.windowBackground
        window.acceptsMouseMovedEvents = true
        window.isMovableByWindowBackground = false
        let content = NSView()
        content.wantsLayer = true
        window.contentView = content
        metalView = AvatarMetalView(frame: .zero, device: renderer.device)
        metalView.renderer = renderer
        metalView.delegate = renderer
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.depthStencilPixelFormat = .depth32Float
        metalView.sampleCount = 1
        metalView.preferredFramesPerSecond = 60
        metalView.clearColor = Self.avatarBackground
        metalView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(metalView)

        // The avatar fills the window; controls float over it and open their panels as popovers.
        controlBar = buildControlBar()
        statusView = buildStatusView()
        captionsView = buildCaptionsView()
        miniBar = buildMiniBar()
        for view in [statusView!, captionsView!, controlBar!, miniBar!] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        let shadow = FloatingSurface.shadowMargin
        let titlebar = window.contentLayoutGuide as! NSLayoutGuide
        NSLayoutConstraint.activate([
            metalView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            metalView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            metalView.topAnchor.constraint(equalTo: content.topAnchor),
            metalView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            statusView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14 - shadow),
            statusView.topAnchor.constraint(equalTo: titlebar.topAnchor, constant: 6 - shadow),
            controlBar.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            controlBar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: shadow - 18),
            miniBar.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            miniBar.bottomAnchor.constraint(equalTo: controlBar.bottomAnchor),
            captionsView.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            captionsView.bottomAnchor.constraint(equalTo: controlBar.topAnchor, constant: shadow * 2 - 10),
            captionsView.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, constant: shadow * 2 - 32)
        ])
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.renderer.transparent, event.window === self.window, event.keyCode == 53 else { return event }
            self.setDesktopMode(false)
            return nil
        }
        buildPanels()
        refreshModelControls()
        refreshCaptions()
        refreshOverlays()
        window.center()
        if show {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func buildControlBar() -> NSView {
        let surface = FloatingSurface()
        surface.cornerRadius = 24
        for button in [characterButton, faceButton, viewButton] {
            button.target = self; button.action = #selector(togglePanel(_:))
        }
        voiceButton.target = self; voiceButton.action = #selector(toggleVoice)
        muteButton.setButtonType(.pushOnPushOff)
        muteButton.target = self; muteButton.action = #selector(toggleMicrophone)
        muteButton.isEnabled = false
        chatButton.target = self; chatButton.action = #selector(toggleChat)
        memoryButton.target = self; memoryButton.action = #selector(showMemories)
        // Equal-width side groups keep the voice button centered.
        let leading = NSStackView(), trailing = NSStackView()
        for view in [characterButton, faceButton, viewButton] { leading.addView(view, in: .trailing) }
        for view in [muteButton, chatButton, memoryButton] { trailing.addView(view, in: .leading) }
        for group in [leading, trailing] {
            group.spacing = 2
            group.setHuggingPriority(.defaultLow, for: .horizontal)
        }
        let bar = NSStackView(views: [leading, voiceButton, trailing])
        bar.spacing = 18
        bar.alignment = .centerY
        bar.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(bar)
        let inset = FloatingSurface.shadowMargin
        NSLayoutConstraint.activate([
            leading.widthAnchor.constraint(equalTo: trailing.widthAnchor),
            bar.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: inset + 12),
            bar.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -inset - 12),
            bar.topAnchor.constraint(equalTo: surface.topAnchor, constant: inset + 8),
            bar.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -inset - 8)
        ])
        return surface
    }

    /// Desktop mode keeps only voice and a way back to the full window.
    func buildMiniBar() -> NSView {
        let surface = FloatingSurface()
        surface.cornerRadius = 25
        miniVoiceButton.target = self; miniVoiceButton.action = #selector(toggleVoice)
        showWindowButton.target = self; showWindowButton.action = #selector(toggleDesktopMode(_:))
        let row = NSStackView(views: [miniVoiceButton, showWindowButton])
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(row)
        let inset = FloatingSurface.shadowMargin + 6
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: inset),
            row.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -inset),
            row.topAnchor.constraint(equalTo: surface.topAnchor, constant: inset),
            row.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -inset)
        ])
        return surface
    }

    func buildStatusView() -> NSView {
        let surface = FloatingSurface()
        surface.cornerRadius = 16
        modelLabel = NSTextField(labelWithString: "")
        modelLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        voiceStatus.font = .systemFont(ofSize: 11)
        voiceStatus.textColor = .secondaryLabelColor
        voiceStatus.maximumNumberOfLines = 2
        voiceStatus.preferredMaxLayoutWidth = 260
        let text = NSStackView(views: [modelLabel, voiceStatus])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        let row = NSStackView(views: [statusDot, text])
        row.spacing = 9
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(row)
        let inset = FloatingSurface.shadowMargin
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: inset + 12),
            row.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -inset - 14),
            row.topAnchor.constraint(equalTo: surface.topAnchor, constant: inset + 7),
            row.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -inset - 7)
        ])
        return surface
    }

    func buildCaptionsView() -> NSView {
        let surface = FloatingSurface()
        surface.cornerRadius = 16
        captionHint.font = .systemFont(ofSize: 12)
        captionHint.textColor = .secondaryLabelColor
        userCaption.font = .systemFont(ofSize: 12)
        userCaption.textColor = .secondaryLabelColor
        userCaption.maximumNumberOfLines = 3
        assistantCaption.font = .systemFont(ofSize: 14)
        assistantCaption.maximumNumberOfLines = 4
        for caption in [captionHint, userCaption, assistantCaption] { caption.preferredMaxLayoutWidth = 540 }
        let stack = NSStackView(views: [captionHint, userCaption, assistantCaption])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(stack)
        let inset = FloatingSurface.shadowMargin
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: inset + 16),
            stack.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -inset - 16),
            stack.topAnchor.constraint(equalTo: surface.topAnchor, constant: inset + 10),
            stack.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -inset - 10)
        ])
        return surface
    }

    func buildPanels() {
        func popover(_ controller: NSViewController) -> NSPopover {
            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = true
            popover.appearance = NSAppearance(named: .aqua)
            popover.contentViewController = controller
            popover.delegate = self
            return popover
        }

        avatarPicker.target = self; avatarPicker.action = #selector(changeAvatar)
        avatarPicker.segmentDistribution = .fillEqually
        avatarPicker.controlSize = .large
        modelStats = PanelLayout.text("", width: 264)
        modelCredits = PanelLayout.text("", size: 11, width: 264)
        panels[characterButton] = popover(PanelLayout.panel(width: 300, [
            PanelLayout.header("Character"), avatarPicker, modelStats, modelCredits
        ], gaps: [modelStats: 18]))

        automaticEmotion.state = .on
        automaticEmotion.target = self; automaticEmotion.action = #selector(toggleAutomaticEmotion)
        emotionPicker.addItems(withTitles: ["Manual pose"] + AvatarEmotion.allCases.map(\.title))
        emotionChips = ChipGrid(columns: 3, target: self, action: #selector(chooseEmotion(_:)))
        emotionChips.setItems(AvatarEmotion.allCases.map { ($0.title, nil) })
        expressionChips = ChipGrid(columns: 3, target: self, action: #selector(chooseExpression(_:)))
        motionChips = ChipGrid(columns: 3, target: self, action: #selector(chooseMotion(_:)))
        for model in [emotionPicker, expression, motions] { model.onSelect = { [weak self] in self?.syncChips() } }
        mouth.target = self; mouth.action = #selector(changeMouth)
        mouth.isContinuous = true
        let automatic = PanelLayout.switchRow("Automatic emotions", detail: "Reacts to the conversation while talking",
                                              toggle: automaticEmotion)
        panels[faceButton] = popover(PanelLayout.panel(width: 372, [
            automatic,
            PanelLayout.header("Emotion"), emotionChips,
            PanelLayout.header("Expression"), expressionChips,
            PanelLayout.header("Motion"), motionChips,
            PanelLayout.header("Mouth opening"), mouth
        ], gaps: [automatic: 18, emotionChips: 18, expressionChips: 18, motionChips: 18]))

        follow.target = self; follow.action = #selector(toggleFollow(_:))
        follow.state = renderer.followsMouse ? .on : .off
        let followRow = PanelLayout.switchRow("Follow mouse", detail: "Eyes and head track the pointer", toggle: follow)
        pause.target = self; pause.action = #selector(togglePause(_:))
        let pauseRow = PanelLayout.switchRow("Pause animation", detail: "Freeze the avatar", toggle: pause)
        desktopMode.target = self; desktopMode.action = #selector(toggleDesktopMode(_:))
        let desktopRow = PanelLayout.switchRow("Desktop mode", detail: "Avatar only, with voice and window buttons",
                                               toggle: desktopMode)
        let reset = NSButton(title: "Reset pose & view", target: self, action: #selector(reset))
        panels[viewButton] = popover(PanelLayout.panel(width: 290, [
            followRow, pauseRow, desktopRow, reset,
            PanelLayout.text("Drag to reposition, scroll to zoom. In desktop mode, drag moves the window and scrolling is off.",
                             size: 11, width: 254)
        ], gaps: [desktopRow: 16]))
    }

    @objc func togglePanel(_ sender: NSButton) {
        guard let popover = panels[sender], let view = popover.contentViewController?.view else { return }
        // A transient popover closes on the same click that would reopen it.
        if popover.isShown || (lastPanelClose?.popover === popover && CACurrentMediaTime() - lastPanelClose!.time < 0.3) {
            popover.performClose(sender)
            return
        }
        view.layoutSubtreeIfNeeded()
        popover.contentSize = view.fittingSize
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: sender.isFlipped ? .minY : .maxY)
        (sender as? BarButton)?.isActive = true
    }

    func popoverDidClose(_ notification: Notification) {
        guard let popover = notification.object as? NSPopover else { return }
        lastPanelClose = (popover, CACurrentMediaTime())
        for (button, panel) in panels where panel === popover { (button as? BarButton)?.isActive = false }
    }

    @objc func toggleDesktopMode(_ sender: Any?) {
        // The switch has already flipped its own state; the menu item toggles the current mode.
        setDesktopMode(sender is NSSwitch ? desktopMode.state == .on : !renderer.transparent)
    }

    /// Desktop mode drops the chrome, shadow and background so only the avatar floats over the desktop.
    func setDesktopMode(_ on: Bool) {
        desktopMode.state = on ? .on : .off
        desktopMenuItem.state = desktopMode.state
        guard on != renderer.transparent else { return }
        let frame = window.frame
        renderer.transparent = on
        window.styleMask = on ? [.borderless, .resizable] : Self.titledStyle
        window.setFrame(frame, display: false)
        window.isOpaque = !on
        window.backgroundColor = on ? .clear : Self.windowBackground
        window.hasShadow = !on
        window.level = on ? .floating : .normal
        metalView.layer?.isOpaque = !on
        metalView.clearColor = on ? MTLClearColorMake(0, 0, 0, 0) : Self.avatarBackground
        metalView.movesWindow = on
        if on { panels.values.forEach { $0.close() } }
        if window.isVisible { window.makeKeyAndOrderFront(nil) }
        refreshOverlays()
    }

    /// Desktop mode swaps the full bar and status for the two-button pill.
    func refreshOverlays() {
        statusView.isHidden = renderer.transparent
        controlBar.isHidden = renderer.transparent
        miniBar.isHidden = !renderer.transparent
    }

    @objc func chooseEmotion(_ sender: NSButton) { emotionPicker.selectItem(at: sender.tag + 1); changeEmotion() }
    @objc func chooseExpression(_ sender: NSButton) { expression.selectItem(at: sender.tag); changeExpression() }
    @objc func chooseMotion(_ sender: NSButton) { motions.selectItem(at: sender.tag); playMotion() }

    func syncChips() {
        emotionChips?.select(emotionPicker.indexOfSelectedItem - 1)
        expressionChips?.select(expression.indexOfSelectedItem)
        motionChips?.select(motionItems.isEmpty ? nil : motions.indexOfSelectedItem)
    }

    func refreshCaptions() {
        let empty = userCaption.stringValue.isEmpty && assistantCaption.stringValue.isEmpty
        captionHint.isHidden = !empty
        userCaption.isHidden = userCaption.stringValue.isEmpty
        assistantCaption.isHidden = assistantCaption.stringValue.isEmpty
        captionsView.isHidden = !voiceLive
    }

    func refreshModelControls() {
        window.title = "Live2D Avatar · \(renderer.modelName)"
        chatWindow?.subtitle = renderer.avatar?.persona.name ?? renderer.modelName
        avatarPicker.selectedSegment = renderer.avatar.flatMap { availableAvatars.firstIndex(of: $0) } ?? -1
        modelLabel.stringValue = renderer.avatar?.persona.name ?? renderer.modelName
        characterButton.title = renderer.avatar?.persona.name ?? "Character"
        modelStats.stringValue = "\(renderer.avatar?.title ?? "Custom model") · \(renderer.model.parameterCount) parameters · \(renderer.model.drawableCount) meshes"
        modelCredits.stringValue = renderer.avatar?.credits ?? "Model: \(renderer.modelName)"
        expression.removeAllItems()
        expression.addItem(withTitle: "Neutral")
        expression.addItems(withTitles: renderer.expressions.map(\.name))
        expression.item(at: 0)?.toolTip = renderer.avatar?.persona.defaultExpressionDescription
        for (index, preset) in renderer.expressions.enumerated() {
            expression.item(at: index + 1)?.toolTip = preset.description
        }
        expression.selectItem(at: 0)
        transientVoiceExpression = false
        motions.removeAllItems()
        motionItems.removeAll()
        for (group, actions) in (renderer.manifest.FileReferences.Motions ?? [:]).sorted(by: { $0.key < $1.key }) {
            for (index, action) in actions.enumerated() {
                motions.addItem(withTitle: URL(fileURLWithPath: action.File).lastPathComponent.replacingOccurrences(of: ".motion3.json", with: ""))
                motionItems.append((group, index))
            }
        }
        if motionItems.isEmpty { motions.addItem(withTitle: "No motions") }
        if renderer.avatar != nil { motions.selectItem(withTitle: "Smile") }
        motions.isEnabled = !motionItems.isEmpty
        mouth.doubleValue = 0
        emotionPicker.selectItem(withTitle: renderer.emotion?.title ?? "Manual pose")
        automaticEmotion.isEnabled = renderer.avatar != nil
        emotionPicker.isEnabled = renderer.avatar != nil
        emotionChips.chips.forEach { $0.isEnabled = renderer.avatar != nil }
        expressionChips.setItems(expression.itemArray.map { ($0.title, $0.toolTip) })
        motionChips.setItems(motionItems.isEmpty ? [] : motions.itemTitles.map { ($0, nil) })
        syncChips()
    }

    @objc func changeAvatar() {
        guard availableAvatars.indices.contains(avatarPicker.selectedSegment) else { return }
        let avatar = availableAvatars[avatarPicker.selectedSegment]
        do { try selectAvatar(avatar) }
        catch {
            avatarPicker.selectedSegment = renderer.avatar.flatMap { availableAvatars.firstIndex(of: $0) } ?? -1
            NSAlert(error: error).beginSheetModal(for: window)
        }
    }

    func selectAvatar(_ avatar: BundledAvatar) throws {
        let directory = resourceDirectory().appendingPathComponent(avatar.directoryName)
        guard directory.standardizedFileURL != renderer.modelDirectory.standardizedFileURL else { return }
        let wasPaused = metalView.isPaused
        metalView.isPaused = true
        defer { metalView.isPaused = wasPaused }
        try renderer.loadModel(from: directory)
        voiceTask?.cancel()
        voice?.stop()
        emotionDirector?.reset(persona: avatar.persona)
        if automaticEmotion.state != .on { renderer.clearEmotion() }
        refreshModelControls()
    }

    @objc func toggleFollow(_ sender: NSSwitch) {
        defer { updateResponsesContext() }
        renderer.followsMouse = sender.state == .on
        renderer.model.dragX = 0; renderer.model.dragY = 0
    }
    @objc func togglePause(_ sender: NSSwitch) {
        renderer.paused = sender.state == .on
        updateResponsesContext()
    }
    @objc func changeExpression() {
        defer { updateResponsesContext() }
        useManualEmotion()
        renderer.model.resetPose()
        mouth.doubleValue = 0
        if expression.indexOfSelectedItem > 0 {
            renderer.model.setExpression(renderer.manifest.FileReferences.Expressions![expression.indexOfSelectedItem - 1].Name)
        }
    }
    @objc func playMotion() {
        defer { updateResponsesContext() }
        if pause.state == .on { pause.state = .off; togglePause(pause) }
        useManualEmotion()
        startSelectedMotion()
    }

    func startSelectedMotion() {
        guard motionItems.indices.contains(motions.indexOfSelectedItem) else { return }
        let motion = motionItems[motions.indexOfSelectedItem]
        _ = renderer.model.startMotion(withGroup: motion.group, index: motion.index, priority: 3, finishedHandler: nil, beganHandler: nil)
    }
    @objc func changeMouth() { renderer.model.mouthOpen = max(mouth.doubleValue, speechMouth); updateResponsesContext() }
    @objc func reset() {
        defer { updateResponsesContext() }
        useManualEmotion()
        renderer.reset()
        expression.selectItem(at: 0)
        mouth.doubleValue = 0
    }

    func useManualEmotion() {
        transientVoiceExpression = false
        automaticEmotion.state = .off
        emotionDirector?.cancel()
        renderer.clearEmotion()
        emotionPicker.selectItem(withTitle: "Manual pose")
    }

    @objc func changeEmotion() {
        defer { updateResponsesContext() }
        clearTransientVoiceExpression()
        automaticEmotion.state = .off
        emotionDirector?.cancel()
        guard let title = emotionPicker.titleOfSelectedItem,
              let emotion = AvatarEmotion(rawValue: title.lowercased()) else { useManualEmotion(); return }
        applyEmotion(emotion, replay: true)
    }

    @objc func toggleAutomaticEmotion() {
        defer { updateResponsesContext() }
        clearTransientVoiceExpression()
        emotionDirector?.cancel()
        if let persona = renderer.avatar?.persona { emotionDirector?.reset(persona: persona) }
        if automaticEmotion.state == .on { applyEmotion(.happy) }
        else { renderer.clearEmotion(); emotionPicker.selectItem(withTitle: "Manual pose") }
    }

    func applyEmotion(_ emotion: AvatarEmotion, replay: Bool = false) {
        defer { updateResponsesContext() }
        clearTransientVoiceExpression()
        renderer.setEmotion(emotion, replay: replay)
        emotionDirector?.setCurrentEmotion(emotion)
        emotionPicker.selectItem(withTitle: emotion.title)
        if voice?.state == .connected {
            // Thinking context avoids interrupting a spoken sentence for every facial change.
            try? voice?.append("Current performed emotion: \(emotion.rawValue). \(emotion.voiceDirection) Do not announce this direction.")
        }
    }

    func clearTransientVoiceExpression() {
        guard transientVoiceExpression else { return }
        transientVoiceExpression = false
        renderer.model.resetPose()
        expression.selectItem(at: 0)
        changeMouth()
    }

    func applyVoiceExpression(at index: Int) {
        let automatic = automaticEmotion.state == .on
        let currentEmotion = renderer.emotion ?? .happy
        let preset = index > 0 ? renderer.expressions[index - 1] : nil
        expression.selectItem(at: index)
        changeExpression()
        changeMouth()
        guard automatic else { return }
        automaticEmotion.state = .on
        if preset?.isTransient == true {
            // Let the authored face/gesture show without the emotion overlay masking it.
            // The existing speech quiet window will replace it with Happy afterward.
            transientVoiceExpression = true
            emotionDirector?.setCurrentEmotion(.neutral)
        } else {
            applyEmotion(index == 0 ? .happy : currentEmotion)
        }
    }

    func finishAutomaticEmotion() {
        emotionDirector?.cancel()
        if automaticEmotion.state == .on, renderer.avatar != nil { applyEmotion(.happy) }
    }
}

extension AppDelegate {
    func loadMemorySeed() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        memorySeed = try AvatarMemorySeed.load(directory: repository.appendingPathComponent("memory_data"),
            publicFallback: Bundle.main.resourceURL?.appendingPathComponent("memory_data/mem_public.md"))
    }

    func updateVoiceIdentity() {
        guard let voice, voice.state == .connected else { return }
        if let persona = renderer.avatar?.persona {
            try? voice.appendInstructions("Adopt the currently visible avatar's identity now: " + persona.identity)
            try? voice.appendInstructions(persona.voiceInstructions)
            for update in persona.expressionInstructionUpdates { try? voice.appendInstructions(update) }
        }
        updateResponsesContext()
    }

    func updateResponsesContext() {
        guard let voice, voice.state == .connected else { return }
        let instructions = responsesConfiguration.instructions
        guard instructions != lastResponsesInstructions else { return }
        do {
            try voice.updateResponsesInstructions(instructions)
            lastResponsesInstructions = instructions
        } catch { voiceStatus.stringValue = error.localizedDescription; syncChatStatus() }
    }

    var chatIsVisible: Bool { chatWindow?.isVisible == true && chatWindow?.isMiniaturized == false }

    @objc func toggleChat() {
        if chatIsVisible {
            chatWindow?.orderOut(nil)
            chatRenderTask?.cancel(); chatRenderTask = nil
        } else {
            if chatWindow == nil { buildChatWindow() }
            if chatWindow?.isMiniaturized == true { chatWindow?.deminiaturize(nil) }
            renderChat()
            syncChatStatus()
            chatWindow?.makeKeyAndOrderFront(nil)
        }
        refreshChatVisibility()
    }

    func refreshChatVisibility() {
        chatButton.isActive = chatIsVisible
        chatButton.toolTip = chatIsVisible ? "Hide chat (⇧⌘C)" : "Show chat (⇧⌘C)"
        chatMenuItem?.title = chatIsVisible ? "Hide Chat" : "Show Chat"
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === chatWindow {
            sender.orderOut(nil)
            chatRenderTask?.cancel(); chatRenderTask = nil
            refreshChatVisibility()
            return false
        }
        if sender === window {
            // The auxiliary chat must not keep a hidden voice session alive after closing the avatar.
            NSApp.terminate(nil)
            return false
        }
        return true
    }

    func windowDidMiniaturize(_ notification: Notification) { refreshChatVisibility() }
    func windowDidDeminiaturize(_ notification: Notification) {
        refreshChatVisibility()
        if chatIsVisible { renderChat() }
    }

    func buildChatWindow() {
        guard chatWindow == nil else { return }
        let chat = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        chatWindow = chat
        chat.title = "Live2D Avatar · Chat"
        chat.subtitle = renderer.avatar?.persona.name ?? renderer.modelName
        chat.minSize = NSSize(width: 380, height: 400)
        chat.appearance = window.appearance
        chat.isReleasedWhenClosed = false
        chat.delegate = self
        let content = NSView()
        chat.contentView = content
        let title = label("Conversation", size: 22)
        let status = label(voiceStatus.stringValue, size: 12, secondary: true)
        chatStatus = status
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        chatScroll = scroll
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 540, height: 1))
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = true
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.autoresizingMask = [.width]
        text.textContainer?.containerSize = NSSize(width: 540, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true
        text.textContainerInset = NSSize(width: 22, height: 20)
        text.backgroundColor = .textBackgroundColor
        text.delegate = self
        text.setAccessibilityLabel("Conversation transcript")
        scroll.documentView = text
        chatTextView = text
        let clear = NSButton(title: "Clear chat", target: self, action: #selector(clearChat))
        let latest = NSButton(title: "Jump to latest", target: self, action: #selector(chatJumpToLatest))
        chatClearButton = clear; chatLatestButton = latest
        for view in [title, status, scroll, clear, latest] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            title.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            status.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            status.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 5),
            status.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 18),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: clear.topAnchor, constant: -12),
            clear.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            clear.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            latest.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            latest.centerYAnchor.constraint(equalTo: clear.centerYAnchor)
        ])
        chat.center()
        content.layoutSubtreeIfNeeded()
        // The clip view grows from zero during layout; width autoresizing would add that growth
        // on top of the initial frame, so match the visible width once.
        text.setFrameSize(NSSize(width: scroll.contentSize.width, height: text.frame.height))
        renderChat()
    }

    func receiveTranscript(_ fragment: LiveTranscript) {
        let name = renderer.avatar?.persona.name ?? renderer.modelName
        let text = String(((captionText[fragment.speaker] ?? "") + fragment.delta).suffix(1000))
        captionText[fragment.speaker] = text
        let caption = fragment.speaker == .user ? userCaption : assistantCaption
        caption.stringValue = "\(fragment.speaker == .user ? "You" : name): \(text.suffix(220))"
        refreshCaptions()
        chatTranscript.append(fragment, characterName: name)
        chatNeedsRender = true
        scheduleChatRender()
    }

    func receiveBackendMessage(_ message: LiveBackendMessage) {
        guard !message.citations.isEmpty else { return }
        chatTranscript.appendBackend(message, characterName: renderer.avatar?.persona.name ?? renderer.modelName,
            milliseconds: chatTranscript.entries.last?.endMilliseconds ?? 0)
        chatNeedsRender = true
        if !chatIsVisible { toggleChat() }
        else { scheduleChatRender() }
    }

    func scheduleChatRender() {
        guard chatIsVisible, chatRenderTask == nil, !renderingChat else { return }
        chatRenderTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
            guard let self else { return }
            self.chatRenderTask = nil
            if self.chatIsVisible { self.renderChat() }
        }
    }

    func syncChatStatus() { chatStatus?.stringValue = voiceStatus.stringValue }

    @objc func clearChat() {
        chatRenderTask?.cancel(); chatRenderTask = nil
        chatTranscript.clear()
        chatNeedsRender = true
        renderingChat = true
        chatTextView?.setSelectedRange(NSRange(location: 0, length: 0))
        renderingChat = false
        renderChat()
        if let scroll = chatScroll {
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    @objc func chatJumpToLatest() {
        chatTextView?.setSelectedRange(NSRange(location: chatTextView?.string.utf16.count ?? 0, length: 0))
        renderChat()
        if let text = chatTextView { text.scrollRangeToVisible(NSRange(location: text.string.utf16.count, length: 0)) }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        if chatNeedsRender, chatTextView?.selectedRange().length == 0 { scheduleChatRender() }
    }

    func renderChat() {
        guard chatNeedsRender, let text = chatTextView, let scroll = chatScroll,
              text.selectedRange().length == 0 else { return }
        let origin = scroll.contentView.bounds.origin
        let followsLatest = scroll.contentView.bounds.maxY >= text.bounds.maxY - 36
        renderingChat = true
        defer { renderingChat = false }
        let rendered = NSMutableAttributedString()
        let bodyStyle = NSMutableParagraphStyle()
        bodyStyle.lineSpacing = 4
        bodyStyle.paragraphSpacing = 18
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15),
            .foregroundColor: NSColor.labelColor, .paragraphStyle: bodyStyle]
        let secondary: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: bodyStyle]
        if chatTranscript.entries.isEmpty {
            rendered.append(NSAttributedString(string: "Your conversation will appear here.\nStart voice in the avatar window, then speak.", attributes: secondary))
        } else {
            if chatTranscript.wasTrimmed {
                rendered.append(NSAttributedString(string: "Showing recent conversation.\n", attributes: secondary))
            }
            for entry in chatTranscript.entries {
                let seconds = max(0, entry.startMilliseconds) / 1000
                let timestamp = String(format: "%02d:%02d", seconds / 60, seconds % 60)
                let headingStyle = NSMutableParagraphStyle()
                headingStyle.paragraphSpacing = 5
                rendered.append(NSAttributedString(string: "\(entry.name)  ·  \(timestamp)\n", attributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                    .foregroundColor: entry.speaker == .user ? NSColor.secondaryLabelColor : NSColor.systemIndigo,
                    .paragraphStyle: headingStyle]))
                let passage = NSMutableAttributedString(string: entry.text + "\n", attributes: body)
                for citation in entry.citations {
                    let scalars = entry.text.unicodeScalars
                    guard citation.start >= 0, citation.end <= scalars.count, citation.end > citation.start else { continue }
                    let start = scalars.index(scalars.startIndex, offsetBy: citation.start)
                    let end = scalars.index(scalars.startIndex, offsetBy: citation.end)
                    passage.addAttributes([.link: citation.url, .toolTip: citation.title,
                        .foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue],
                        range: NSRange(start..<end, in: entry.text))
                }
                rendered.append(passage)
            }
        }
        text.textStorage?.setAttributedString(rendered)
        text.layoutManager?.ensureLayout(for: text.textContainer!)
        text.sizeToFit()
        if followsLatest { text.scrollRangeToVisible(NSRange(location: text.string.utf16.count, length: 0)) }
        else {
            scroll.contentView.scroll(to: origin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        chatClearButton?.isEnabled = !chatTranscript.entries.isEmpty
        chatLatestButton?.isEnabled = !chatTranscript.entries.isEmpty
        chatNeedsRender = false
    }
}

extension AppDelegate {
    func memoryStore(reload: Bool = false) throws -> AvatarMemory {
        guard let persona = renderer.avatar?.persona else { throw ViewerError.message("Select a configured avatar to use saved memories.") }
        if !reload, let memory = memories[persona] { return memory }
        let loaded = try AvatarMemory(persona: persona, directory: memoryDirectory)
        memories[persona] = loaded
        return loaded
    }

    func performMemoryCommand(arguments: String) async throws -> String {
        let command = try AvatarMemoryCommand(arguments: arguments)
        let store = try memoryStore()
        if let prompt = try command.confirmation(in: store) {
            guard try await confirmMemoryChange(prompt) else { return "The user declined. No memories were changed." }
            try Task.checkCancellation()
        }
        guard renderer.avatar?.persona == store.persona else { throw CancellationError() }
        let result = try command.execute(in: store, confirmed: true)
        if command.action != .list { refreshVoiceMemory() }
        let context = AvatarDelegation.memoryContext(profile: memorySeed, savedMemory: store)
        return command.action == .list ? context : result + "\n\n" + context
    }

    func refreshVoiceMemory() {
        updateResponsesContext()
        guard let voice, voice.state == .connected else { return }
        do {
            try voice.appendInstructions("Saved memory has changed. The initial saved-memory snapshot is stale. Delegate saved-memory recall before answering personal questions again, and use the latest memory_control result. Saved corrections override conflicting profile facts. Deleted facts must not be recalled from older snapshots.")
        } catch { voiceStatus.stringValue = error.localizedDescription; syncChatStatus() }
    }

    func makeVoiceConfiguration() throws -> LiveConfiguration {
        // Reload on every Start, including Stop/Start in the same app process. Never silently
        // fall back to the profile when saved corrections cannot be read.
        let store = renderer.avatar == nil ? nil : try memoryStore(reload: true)
        var configuration = LiveConfiguration(instructions: renderer.avatar?.persona.liveInstructions ??
            "You are a cheerful animated companion named \(renderer.modelName). Your appearance is unspecified; don't invent it. Delegate avatar controls and reasoning. Be concise and emotionally expressive.\n" + AvatarDelegation.liveInstructions)
        configuration.voice = renderer.avatar?.persona.defaultVoice ?? configuration.voice
        configuration.instructions += "\n\n" + AvatarDelegation.memoryContext(profile: memorySeed, savedMemory: store)
        configuration.responses = responsesConfiguration
        return configuration
    }

    func confirmMemoryChange(_ prompt: String) async throws -> Bool {
        try Task.checkCancellation()
        guard window.attachedSheet == nil else { throw ViewerError.message("Close the current dialog and try the memory request again.") }
        let alert = NSAlert()
        alert.messageText = prompt
        alert.informativeText = "Saved facts belong only to the named character and are stored as unencrypted YAML on this Mac. They are sent to OpenAI when voice starts and when recalled. Deleting them does not erase an ongoing conversation. Never save passwords or API keys."
        alert.addButton(withTitle: "Confirm")
        alert.addButton(withTitle: "Cancel")
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { response in continuation.resume(returning: response == .alertFirstButtonReturn) }
            }
        } onCancel: {
            Task { @MainActor in
                alert.window.sheetParent?.endSheet(alert.window, returnCode: .abort)
            }
        }
    }

    @objc func showMemories() {
        guard window.attachedSheet == nil else { return }
        do {
            try loadMemorySeed()
            let store = try memoryStore()
            let alert = NSAlert()
            alert.messageText = "\(store.persona.name)'s memories"
            alert.informativeText = "Only facts explicitly saved for \(store.persona.name). Saved corrections take precedence over the profile below. The other character has a separate memory. Saved as local, unencrypted YAML; sent to OpenAI when voice starts and when recalled."
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 240))
            scroll.hasVerticalScroller = true
            let text = NSTextView(frame: scroll.bounds)
            text.isEditable = false
            text.isSelectable = true
            text.font = .systemFont(ofSize: 13)
            text.autoresizingMask = [.width]
            text.textContainer?.widthTracksTextView = true
            text.string = store.entries.isEmpty ? "No explicitly saved facts." : store.entries.map { "• \($0.text)" }.joined(separator: "\n\n")
            if let memorySeed { text.string += "\n\nRead-only profile: \(memorySeed.filename)\n\n\(memorySeed.text)" }
            scroll.documentView = text
            alert.accessoryView = scroll
            alert.addButton(withTitle: "Close")
            if !store.entries.isEmpty { alert.addButton(withTitle: "Forget all…") }
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertSecondButtonReturn, let self else { return }
                Task { @MainActor in
                    do {
                        guard self.renderer.avatar?.persona == store.persona else { return }
                        if try await self.confirmMemoryChange("Delete all explicitly saved facts for \(store.persona.name) only? The other character's memories and read-only reference profile will not change.") {
                            guard self.renderer.avatar?.persona == store.persona else { return }
                            self.voice?.invalidateResponseTools()
                            try store.clear()
                            self.refreshVoiceMemory()
                            try? self.voice?.append("All explicitly saved facts for \(store.persona.name) have been deleted. The other character's memories and read-only profile are unchanged. Do not rely on previously recalled saved facts. Start a fresh session to clear prior context too.")
                        }
                    } catch { await NSAlert(error: error).beginSheetModal(for: self.window) }
                }
            }
        } catch { NSAlert(error: error).beginSheetModal(for: window) }
    }

    @objc func toggleVoice() {
        defer { syncChatStatus() }
        guard !terminating else { return }
        if let voice, voice.state == .connecting || voice.state == .connected {
            emotionDirector?.cancel()
            voice.stop()
            return
        }
        do {
            try loadMemorySeed()
            let configuration = try makeVoiceConfiguration()
            let http = OpenAIHTTP(apiKey: try LocalOpenAIKey.load())
            let client = GPTLiveClient(service: DirectLiveSessionService(http: http))
            voice = client
            lastResponsesInstructions = nil
            emotionDirector?.cancel()
            emotionDirector = renderer.avatar.map {
                EmotionDirector(http: http, persona: $0.persona,
                    model: ProcessInfo.processInfo.environment["OPENAI_VOICE_BACKEND_MODEL"] ?? "gpt-6-luna")
            }
            emotionDirector?.setCurrentEmotion(renderer.emotion ?? .happy)
            emotionDirector?.onEmotion = { [weak self, weak client] emotion in
                guard let self, let client, self.voice === client, client.state == .connected,
                      self.automaticEmotion.state == .on else { return }
                self.applyEmotion(emotion)
            }
            captionText.removeAll()
            userCaption.stringValue = ""; assistantCaption.stringValue = ""
            refreshCaptions()
            clearChat()
            muteButton.state = .off
            muteButton.isActive = false
            client.onStateChange = { [weak self, weak client] state in
                guard let self, let client, self.voice === client else { return }
                self.refreshVoiceControls(state)
            }
            client.onTranscript = { [weak self, weak client] fragment in
                guard let self, let client, self.voice === client, client.state == .connected else { return }
                self.receiveTranscript(fragment)
                if self.automaticEmotion.state == .on, client.state == .connected {
                    self.emotionDirector?.observe(fragment)
                }
            }
            client.onError = { [weak self, weak client] message in
                guard let self, let client, self.voice === client, client.state == .connected else { return }
                self.voiceStatus.stringValue = message
                self.syncChatStatus()
            }
            client.onAudioLevel = { [weak self, weak client] level in
                guard let self, let client, self.voice === client, self.renderer != nil else { return }
                self.speechMouth = level
                self.changeMouth()
                if self.automaticEmotion.state == .on, client.state == .connected {
                    self.emotionDirector?.observeAudioLevel(level)
                }
            }
            client.onResponseToolCall = { [weak self, weak client] call in
                guard let self, let client, self.voice === client, client.state == .connected else {
                    throw CancellationError()
                }
                try Task.checkCancellation()
                if call.name == "memory_control" { return try await self.performMemoryCommand(arguments: call.arguments) }
                return try self.performVoiceCommand(name: call.name, arguments: call.arguments)
            }
            client.onBackendMessage = { [weak self, weak client] message in
                guard let self, let client, self.voice === client, client.state == .connected else { return }
                self.receiveBackendMessage(message)
            }
            voiceTask = Task { @MainActor [weak self, weak client] in
                guard let self, let client, !Task.isCancelled else { return }
                do { try await client.connect(configuration: configuration) }
                catch {
                    if self.voice === client, client.state == .connecting {
                        self.voiceStatus.stringValue = error.localizedDescription
                        self.syncChatStatus()
                    }
                }
            }
        } catch { voiceStatus.stringValue = error.localizedDescription }
    }

    @objc func toggleMicrophone() {
        voice?.setMuted(muteButton.state == .on)
        muteButton.isActive = muteButton.state == .on
        muteButton.title = muteButton.state == .on ? "Muted" : "Mute"
        if voice?.state == .connected {
            voiceStatus.stringValue = muteButton.state == .on ? "Voice connected · microphone muted" : "Voice connected · microphone live"
            syncChatStatus()
        }
    }

    func refreshVoiceControls(_ state: GPTLiveClient.State) {
        defer { syncChatStatus(); refreshCaptions() }
        voiceButton.isEnabled = state != .closing
        muteButton.isEnabled = state == .connected
        voiceLive = state == .connected
        voiceButton.isActive = state == .connecting || state == .connected
        voiceButton.symbol = voiceButton.isActive ? "xmark" : "mic.fill"
        voiceButton.toolTip = voiceButton.isActive ? "End the voice session" : "Talk with the avatar"
        miniVoiceButton.isEnabled = voiceButton.isEnabled
        miniVoiceButton.symbol = voiceButton.symbol
        miniVoiceButton.fill = voiceButton.isActive ? NSColor(calibratedWhite: 0.42, alpha: 1) : .controlAccentColor
        miniVoiceButton.toolTip = voiceButton.isActive ? "Cancel voice" : "Start voice"
        statusDot.color = state == .connected ? .systemGreen
            : state == .connecting || state == .closing ? .systemOrange : .tertiaryLabelColor
        if case .failed = state { statusDot.color = .systemRed }
        switch state {
        case .idle: voiceStatus.stringValue = "Voice off"
        case .connecting:
            voiceButton.title = "Cancel voice"
            voiceStatus.stringValue = "Connecting…"
        case .connected:
            voiceButton.title = "Cancel voice"
            voiceStatus.stringValue = "Voice connected · microphone live"
            updateVoiceIdentity()
            if let voice { try? voice.append(ResponsesDelegationHandler.brief(voiceContext)) }
        case .closing:
            finishAutomaticEmotion()
            voiceStatus.stringValue = "Finishing voice…"
        case .closed:
            finishAutomaticEmotion()
            voiceButton.title = "Start voice"
            voiceStatus.stringValue = voice?.finalizationConfirmed == true ? "Voice off · session finalized" : "Voice off"
        case .failed(let message):
            finishAutomaticEmotion()
            voiceButton.title = "Start voice"
            voiceStatus.stringValue = message
        }
    }

    var voiceContext: String {
        "Avatar: \(renderer.avatar?.title ?? renderer.modelName). Available avatars: \(availableAvatars.map(\.title).joined(separator: ", ")). " +
        "Current expression: \(expression.titleOfSelectedItem ?? "Neutral"). " +
        "Emotion: \(renderer.emotion?.rawValue ?? "manual"). Automatic emotions: \(automaticEmotion.state == .on). " +
        "Identity: \(renderer.avatar?.persona.identity ?? renderer.modelName). " +
        "Memory owner: \(renderer.avatar?.persona.name ?? "unavailable"); never access the other character's saved facts. " +
        "Expressions replace the previous preset. Neutral: \(renderer.avatar?.persona.defaultExpressionDescription ?? "Reset the authored pose.") " +
        renderer.expressions.map(\.instruction).joined(separator: " ") + " " +
        "Motions: \(motions.itemTitles.joined(separator: ", ")). " +
        "Paused: \(renderer.paused). Follow mouse: \(renderer.followsMouse). Manual mouth: \(mouth.doubleValue)."
    }

    var responsesConfiguration: LiveResponsesConfiguration {
        var configuration = AvatarDelegation.configuration(context: voiceContext,
            model: ProcessInfo.processInfo.environment["OPENAI_VOICE_BACKEND_MODEL"] ?? "gpt-6-luna", memory: memorySeed,
            savedMemory: renderer.avatar.flatMap { memories[$0.persona] })
        configuration.tools = Self.voiceTools + [AvatarDelegation.memoryTool, ["type": "web_search"]]
        return configuration
    }

    static var voiceTools: [[String: Any]] {
        [["type": "function", "name": "avatar_control", "description": "Change the local avatar using an explicit action and value. Motions resume animation. reset uses an empty value.",
          "strict": true, "parameters": ["type": "object", "additionalProperties": false,
            "properties": [
                "action": ["type": "string", "enum": ["switch_avatar", "expression", "motion", "emotion", "pause", "follow_mouse", "mouth", "reset"]],
                "value": ["type": "string", "description": "switch_avatar: an available avatar name from current app state; switching ends voice to isolate memories. emotion: happy, excited, playful, sad, hurt, apologetic, curious, surprised, neutral; expression/motion: exact menu name; pause/follow_mouse: on or off; mouth: 0 to 1; reset: empty string."]
            ], "required": ["action", "value"]]]]
    }

    /// All model-selected actions are validated here and use the same AppKit actions as the controls.
    func performVoiceCommand(name: String, arguments: String) throws -> String {
        defer { updateResponsesContext() }
        struct Command: Decodable { let action: String; let value: String }
        guard name == "avatar_control", let data = arguments.data(using: .utf8), data.count < 4096,
              let command = try? JSONDecoder().decode(Command.self, from: data) else {
            throw ViewerError.message("Unknown or malformed avatar command.")
        }
        let value = command.value
        func toggleValue() throws -> NSControl.StateValue {
            guard value == "on" || value == "off" else { throw ViewerError.message("Use on or off.") }
            return value == "on" ? .on : .off
        }
        switch command.action {
        case "switch_avatar":
            guard let avatar = availableAvatars.first(where: {
                $0.title.caseInsensitiveCompare(value) == .orderedSame || $0.persona.name.caseInsensitiveCompare(value) == .orderedSame
            }) else {
                throw ViewerError.message("Choose an avatar listed in the selector.")
            }
            try selectAvatar(avatar)
        case "emotion":
            guard let emotion = AvatarEmotion(rawValue: value.lowercased()), renderer.avatar != nil else {
                throw ViewerError.message("That emotion is not supported on this avatar.")
            }
            applyEmotion(emotion)
        case "expression":
            let index = expression.itemTitles.firstIndex { $0.caseInsensitiveCompare(value) == .orderedSame } ??
                renderer.expressions.firstIndex { $0.id.caseInsensitiveCompare(value) == .orderedSame }.map { $0 + 1 }
            guard let index else { throw ViewerError.message("That expression is not available on this avatar.") }
            applyVoiceExpression(at: index)
        case "motion":
            guard let index = motions.itemTitles.firstIndex(of: value), motionItems.indices.contains(index) else {
                throw ViewerError.message("That motion is not available on this avatar.")
            }
            pause.state = .off; togglePause(pause)
            motions.selectItem(at: index)
            if automaticEmotion.state == .on {
                // A spoken smile/sad command should not silently disable future reactions.
                if let emotion = ["Smile": AvatarEmotion.happy, "Sad": .sad, "Neutral mouth": .neutral][value] {
                    applyEmotion(emotion)
                }
                startSelectedMotion()
            } else { playMotion() }
        case "pause": pause.state = try toggleValue(); togglePause(pause)
        case "follow_mouse": follow.state = try toggleValue(); toggleFollow(follow)
        case "mouth":
            guard let amount = Double(value), amount.isFinite, (0...1).contains(amount) else { throw ViewerError.message("Mouth opening must be between 0 and 1.") }
            mouth.doubleValue = amount; changeMouth()
        case "reset":
            guard value.isEmpty else { throw ViewerError.message("Reset takes an empty value.") }
            reset()
        default: throw ViewerError.message("That avatar action is not supported.")
        }
        return "Completed \(command.action) \(value). \(voiceContext)"
    }
}

/// Main avatar window. A borderless window (desktop mode) must opt in to key status for popovers and shortcuts.
final class AvatarWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Rounded translucent surface floating over the avatar. Drawn in `draw(_:)` rather than with layer
/// properties so smoke-test captures (`cacheDisplay`) match the window.
final class FloatingSurface: NSView {
    static let shadowMargin: CGFloat = 10
    var cornerRadius: CGFloat = 20

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: Self.shadowMargin, dy: Self.shadowMargin)
        let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.14)
        shadow.shadowBlurRadius = 9
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.set()
        NSColor(calibratedWhite: 1, alpha: 0.9).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.black.withAlphaComponent(0.07).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

/// Icon-over-label button for the control bar. `isActive` marks an open panel or a running feature.
final class BarButton: NSButton {
    var isActive = false { didSet { contentTintColor = isActive ? .controlAccentColor : .labelColor; needsDisplay = true } }
    private var hovering = false { didSet { needsDisplay = true } }
    private var hoverArea: NSTrackingArea?
    private var symbol = ""

    init(symbol: String, title: String, toolTip: String) {
        super.init(frame: .zero)
        self.title = title
        self.toolTip = toolTip
        setSymbol(symbol)
        imagePosition = .imageAbove
        isBordered = false
        font = .systemFont(ofSize: 10.5, weight: .medium)
        contentTintColor = .labelColor
        (cell as? NSButtonCell)?.highlightsBy = []
        (cell as? NSButtonCell)?.showsStateBy = []
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: 76), heightAnchor.constraint(equalToConstant: 50)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setSymbol(_ name: String) {
        symbol = name
        image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        needsDisplay = true
    }

    override var title: String { didSet { needsDisplay = true } }
    override var isHighlighted: Bool { didSet { needsDisplay = true } }
    override var isEnabled: Bool { didSet { needsDisplay = true } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { hovering = isEnabled }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        if isActive || (isEnabled && (hovering || isHighlighted)) {
            let fill = isActive ? NSColor.controlAccentColor.withAlphaComponent(isHighlighted ? 0.22 : 0.13)
                : NSColor.black.withAlphaComponent(isHighlighted ? 0.1 : 0.05)
            fill.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 11, yRadius: 11).fill()
        }
        // The cell's imageAbove layout sits off-centre in a fixed frame, so the icon and label are
        // drawn here as one block centred in the button.
        let tint = isEnabled ? contentTintColor ?? .labelColor : .tertiaryLabelColor
        drawCentered(in: self, symbol: symbol, pointSize: 17, weight: .regular, title: title,
                     font: font ?? .systemFont(ofSize: 10.5), color: tint, vertical: true, spacing: 4)
    }
}

/// Primary pill in the middle of the bar: Start voice, then Cancel voice while a session runs.
final class VoiceButton: NSButton {
    var isActive = false { didSet { needsDisplay = true } }
    var symbol = "mic.fill" { didSet { needsDisplay = true } }

    init() {
        super.init(frame: .zero)
        title = "Start voice"
        toolTip = "Talk with the avatar"
        isBordered = false
        imagePosition = .noImage
        (cell as? NSButtonCell)?.highlightsBy = []
        (cell as? NSButtonCell)?.showsStateBy = []
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: 172), heightAnchor.constraint(equalToConstant: 52)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var title: String { didSet { needsDisplay = true } }
    override var isHighlighted: Bool { didSet { needsDisplay = true } }
    override var isEnabled: Bool { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let pill = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        (isActive ? NSColor(calibratedWhite: 0.42, alpha: 1) : .controlAccentColor).withAlphaComponent(isEnabled ? 1 : 0.45).setFill()
        pill.fill()
        if isHighlighted {
            NSColor.black.withAlphaComponent(0.14).setFill()
            pill.fill()
        }
        drawCentered(in: self, symbol: symbol, pointSize: 16, weight: .semibold, title: title,
                     font: .systemFont(ofSize: 15, weight: .semibold), color: .white, vertical: false, spacing: 8)
    }
}

/// Small round icon button for the desktop-mode pill. `fill` nil draws a white bordered circle.
final class MiniButton: NSButton {
    var symbol: String { didSet { needsDisplay = true } }
    var fill: NSColor? { didSet { needsDisplay = true } }

    init(symbol: String, toolTip: String, fill: NSColor? = nil) {
        self.symbol = symbol
        self.fill = fill
        super.init(frame: .zero)
        title = ""
        self.toolTip = toolTip
        setAccessibilityLabel(toolTip)
        isBordered = false
        imagePosition = .noImage
        (cell as? NSButtonCell)?.highlightsBy = []
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: 38), heightAnchor.constraint(equalToConstant: 38)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isHighlighted: Bool { didSet { needsDisplay = true } }
    override var isEnabled: Bool { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
        (fill ?? .white).withAlphaComponent(isEnabled ? 1 : 0.45).setFill()
        circle.fill()
        if fill == nil {
            NSColor.black.withAlphaComponent(0.14).setStroke()
            circle.stroke()
        }
        if isHighlighted {
            NSColor.black.withAlphaComponent(0.14).setFill()
            circle.fill()
        }
        drawCentered(in: self, symbol: symbol, pointSize: 14, weight: .semibold, title: "", font: .systemFont(ofSize: 1),
                     color: fill == nil ? NSColor(calibratedWhite: 0.16, alpha: 1) : .white, vertical: false, spacing: 0)
    }
}

/// Draws a symbol and a label as one block centred in `view`, stacked or side by side.
private func drawCentered(in view: NSView, symbol: String, pointSize: CGFloat, weight: NSFont.Weight, title: String,
                          font: NSFont, color: NSColor, vertical: Bool, spacing: CGFloat) {
    let bounds = view.bounds
    let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: pointSize, weight: weight).applying(.init(paletteColors: [color])))
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    style.lineBreakMode = .byTruncatingTail
    let label = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
    let iconSize = icon?.size ?? .zero
    let labelSize = NSSize(width: min(ceil(label.size().width), bounds.width - 8), height: ceil(label.size().height))
    let gap = icon == nil || title.isEmpty ? 0 : spacing
    // Positions are measured from the top-left, then converted for unflipped views.
    func place(_ x: CGFloat, _ top: CGFloat, _ size: NSSize) -> NSRect {
        NSRect(x: x, y: view.isFlipped ? top : bounds.height - top - size.height, width: size.width, height: size.height)
    }
    let iconRect: NSRect, labelRect: NSRect
    if vertical {
        // A fixed icon box keeps labels on one baseline across symbols of different heights.
        let box = ceil(pointSize * 1.3)
        let top = floor((bounds.height - box - gap - labelSize.height) / 2)
        iconRect = place(round((bounds.width - iconSize.width) / 2), top + round((box - iconSize.height) / 2), iconSize)
        labelRect = place(round((bounds.width - labelSize.width) / 2), top + box + gap, labelSize)
    } else {
        let left = round((bounds.width - iconSize.width - gap - labelSize.width) / 2)
        iconRect = place(left, round((bounds.height - iconSize.height) / 2), iconSize)
        labelRect = place(left + iconSize.width + gap, round((bounds.height - labelSize.height) / 2), labelSize)
    }
    icon?.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    label.draw(with: labelRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
}

/// Voice connection indicator in the status pill.
final class StatusDot: NSView {
    var color: NSColor = .tertiaryLabelColor { didSet { needsDisplay = true } }
    override var intrinsicContentSize: NSSize { NSSize(width: 8, height: 8) }
    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}

/// Selectable pill used by panel grids. The owner keeps the selection model.
final class ChipButton: NSButton {
    var isSelected = false { didSet { needsDisplay = true } }

    override var isHighlighted: Bool { didSet { needsDisplay = true } }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 28) }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        let fill = isSelected ? NSColor.controlAccentColor
            : NSColor.black.withAlphaComponent(isHighlighted ? 0.12 : isEnabled ? 0.05 : 0.03)
        fill.setFill()
        path.fill()
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        let text = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: isSelected ? .semibold : .regular),
            .foregroundColor: isSelected ? NSColor.white : isEnabled ? NSColor.labelColor : NSColor.tertiaryLabelColor,
            .paragraphStyle: style])
        let height = text.size().height
        text.draw(in: NSRect(x: 6, y: (bounds.height - height) / 2, width: bounds.width - 12, height: height))
    }
}

/// Equal-width chip rows. Chip tags are item indices, so callers route clicks through `sender.tag`.
final class ChipGrid: NSStackView {
    let columns: Int
    private weak var chipTarget: AnyObject?
    private let chipAction: Selector
    private(set) var chips: [ChipButton] = []

    init(columns: Int, target: AnyObject, action: Selector) {
        self.columns = columns
        chipTarget = target
        chipAction = action
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setItems(_ items: [(title: String, toolTip: String?)]) {
        arrangedSubviews.forEach { $0.removeFromSuperview() }
        chips = items.enumerated().map { index, item in
            let chip = ChipButton(title: item.title, target: chipTarget, action: chipAction)
            chip.tag = index
            chip.toolTip = item.toolTip ?? item.title
            chip.isBordered = false
            chip.setAccessibilityLabel(item.title)
            return chip
        }
        for start in stride(from: 0, to: chips.count, by: columns) {
            let row: [NSView] = Array(chips[start..<min(start + columns, chips.count)])
            // Pad the final row so every chip keeps the same width.
            let line = NSStackView(views: row + (row.count..<columns).map { _ in NSView() })
            line.distribution = .fillEqually
            line.spacing = 6
            addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
    }

    func select(_ index: Int?) {
        for chip in chips { chip.isSelected = chip.tag == index }
    }
}

/// Pop-up kept off-screen as the selection model behind a chip grid; reports every selection change.
final class ObservedPopUpButton: NSPopUpButton {
    var onSelect: (() -> Void)?
    override func select(_ item: NSMenuItem?) { super.select(item); onSelect?() }
    override func selectItem(at index: Int) { super.selectItem(at: index); onSelect?() }
    override func selectItem(withTitle title: String) { super.selectItem(withTitle: title); onSelect?() }
}

/// Builders shared by the floating panels.
enum PanelLayout {
    static func header(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text.uppercased())
        label.font = .systemFont(ofSize: 10.5, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    static func text(_ text: String, size: CGFloat = 12, secondary: Bool = true, width: CGFloat) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: size)
        label.textColor = secondary ? .secondaryLabelColor : .labelColor
        label.preferredMaxLayoutWidth = width
        return label
    }

    static func switchRow(_ title: String, detail: String? = nil, toggle: NSSwitch) -> NSView {
        toggle.controlSize = .small
        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        let labels = NSStackView(views: [name])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1
        if let detail {
            let note = NSTextField(labelWithString: detail)
            note.font = .systemFont(ofSize: 11)
            note.textColor = .secondaryLabelColor
            labels.addArrangedSubview(note)
        }
        let row = NSStackView(views: [labels, NSView(), toggle])
        row.distribution = .fill
        row.alignment = .centerY
        labels.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        return row
    }

    /// A fixed-width vertical panel whose children span the content width.
    static func panel(width: CGFloat, _ views: [NSView], gaps: [NSView: CGFloat] = [:]) -> NSViewController {
        let inset: CGFloat = 18
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: width).isActive = true
        for view in views {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -inset * 2).isActive = true
        }
        for (view, gap) in gaps { stack.setCustomSpacing(gap, after: view) }
        let controller = NSViewController()
        controller.view = stack
        return controller
    }
}

func resourceDirectory() -> URL {
    // A packaged app is self-contained. SwiftPM/Xcode runs use the same resources
    // prepared by scripts/build.sh, located relative to this source file.
    let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    return Bundle.main.bundleURL.pathExtension == "app"
        ? Bundle.main.resourceURL!
        : project.appendingPathComponent("build/Live2D Avatar.app/Contents/Resources")
}

func makeRenderer() throws -> AvatarRenderer {
    let resources = resourceDirectory()
    let args = CommandLine.arguments
    let model: URL
    if let index = args.firstIndex(of: "--model"), args.indices.contains(index + 1) {
        model = URL(fileURLWithPath: args[index + 1], isDirectory: true)
    } else {
        let preferred = Bundle.main.object(forInfoDictionaryKey: "Live2DDefaultModel") as? String
        let initialAvatar = BundledAvatar.available(in: resources).first { $0.directoryName == preferred } ?? .sample
        model = resources.appendingPathComponent(initialAvatar.directoryName)
    }
    return try AvatarRenderer(modelDirectory: model, shaderDirectory: resources.appendingPathComponent("Shaders"))
}

@MainActor
func smokeTest(output: URL) throws {
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let renderer = try makeRenderer()
    try verifyPublicModel(renderer: renderer, output: output)
}

MainActor.assumeIsolated {
    if let index = CommandLine.arguments.firstIndex(of: "--smoke-test") {
        let path = CommandLine.arguments.indices.contains(index + 1) ? CommandLine.arguments[index + 1] : "build/verification"
        do { try smokeTest(output: URL(fileURLWithPath: path, isDirectory: true)) }
        catch { fputs("Smoke test failed: \(error.localizedDescription)\n", stderr); exit(1) }
    } else {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
