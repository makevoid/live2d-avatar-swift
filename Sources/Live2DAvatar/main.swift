import AppKit
import Cubism
import MetalKit
import GPTLiveSwift
import AvatarBehavior

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextViewDelegate {
    var window: NSWindow!
    var renderer: AvatarRenderer!
    var metalView: AvatarMetalView!
    let expression = NSPopUpButton()
    let motions = NSPopUpButton()
    let mouth = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    let availableAvatars = BundledAvatar.available(in: resourceDirectory())
    lazy var avatarPicker = NSSegmentedControl(labels: availableAvatars.map { $0.title },
                                          trackingMode: .selectOne, target: nil, action: nil)
    let play = NSButton(title: "Play motion", target: nil, action: nil)
    let follow = NSButton(checkboxWithTitle: "Follow mouse", target: nil, action: nil)
    let pause = NSButton(checkboxWithTitle: "Pause animation", target: nil, action: nil)
    let voiceButton = NSButton(title: "Start voice", target: nil, action: nil)
    let muteButton = NSButton(checkboxWithTitle: "Mute microphone", target: nil, action: nil)
    let chatButton = NSButton(title: "Show chat", target: nil, action: nil)
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
    let emotionPicker = NSPopUpButton()
    let automaticEmotion = NSButton(checkboxWithTitle: "Automatic emotions", target: nil, action: nil)
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
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 850),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 760, height: 760)
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = NSColor(calibratedWhite: 0.98, alpha: 1)
        window.acceptsMouseMovedEvents = true
        let content = NSView()
        window.contentView = content
        metalView = AvatarMetalView(frame: .zero, device: renderer.device)
        metalView.renderer = renderer
        metalView.delegate = renderer
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.depthStencilPixelFormat = .depth32Float
        metalView.sampleCount = 1
        metalView.preferredFramesPerSecond = 60
        metalView.clearColor = MTLClearColorMake(0.93, 0.94, 0.95, 1)
        metalView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(metalView)

        let sidebarScroll = NSScrollView()
        sidebarScroll.hasVerticalScroller = true
        sidebarScroll.drawsBackground = true
        sidebarScroll.backgroundColor = window.backgroundColor
        sidebarScroll.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(sidebarScroll)
        let sidebar = NSStackView()
        sidebar.orientation = .vertical
        sidebar.alignment = .leading
        sidebar.spacing = 14
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebarScroll.documentView = sidebar
        NSLayoutConstraint.activate([
            metalView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            metalView.topAnchor.constraint(equalTo: content.topAnchor),
            metalView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            metalView.trailingAnchor.constraint(equalTo: sidebarScroll.leadingAnchor, constant: -24),
            sidebarScroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            sidebarScroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            sidebarScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            sidebarScroll.widthAnchor.constraint(equalToConstant: 270),
            sidebar.leadingAnchor.constraint(equalTo: sidebarScroll.contentView.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: sidebarScroll.contentView.topAnchor),
            sidebar.widthAnchor.constraint(equalTo: sidebarScroll.widthAnchor, constant: -16)
        ])
        modelLabel = label("", size: 11, secondary: true)
        sidebar.addArrangedSubview(modelLabel)
        sidebar.addArrangedSubview(label("Avatar studio", size: 25))
        sidebar.addArrangedSubview(label("Live2D · Native Metal", secondary: true))
        avatarPicker.target = self; avatarPicker.action = #selector(changeAvatar)
        sidebar.addArrangedSubview(avatarPicker)
        modelStats = label("", secondary: true)
        sidebar.addArrangedSubview(modelStats)

        voiceButton.target = self; voiceButton.action = #selector(toggleVoice)
        sidebar.addArrangedSubview(voiceButton)
        chatButton.target = self; chatButton.action = #selector(toggleChat)
        sidebar.addArrangedSubview(chatButton)
        sidebar.addArrangedSubview(NSButton(title: "Saved memories…", target: self, action: #selector(showMemories)))
        muteButton.target = self; muteButton.action = #selector(toggleMicrophone)
        muteButton.isEnabled = false
        sidebar.addArrangedSubview(muteButton)
        voiceStatus.font = .systemFont(ofSize: 12)
        voiceStatus.textColor = .secondaryLabelColor
        sidebar.addArrangedSubview(voiceStatus)
        for caption in [userCaption, assistantCaption] {
            caption.font = .systemFont(ofSize: 12)
            caption.maximumNumberOfLines = 4
            sidebar.addArrangedSubview(caption)
        }
        sidebar.addArrangedSubview(label("Try “smile” or “pause animation”.", size: 11, secondary: true))
        automaticEmotion.state = .on
        automaticEmotion.target = self; automaticEmotion.action = #selector(toggleAutomaticEmotion)
        sidebar.addArrangedSubview(automaticEmotion)
        sidebar.addArrangedSubview(label("Emotion"))
        emotionPicker.addItems(withTitles: ["Manual pose"] + AvatarEmotion.allCases.map(\.title))
        emotionPicker.target = self; emotionPicker.action = #selector(changeEmotion)
        sidebar.addArrangedSubview(emotionPicker)
        follow.target = self; follow.action = #selector(toggleFollow(_:))
        follow.state = renderer.followsMouse ? .on : .off
        sidebar.addArrangedSubview(follow)
        pause.target = self; pause.action = #selector(togglePause(_:))
        sidebar.addArrangedSubview(pause)
        sidebar.addArrangedSubview(label("Expression"))
        expression.target = self; expression.action = #selector(changeExpression)
        sidebar.addArrangedSubview(expression)
        sidebar.addArrangedSubview(label("Motion"))
        sidebar.addArrangedSubview(motions)
        play.target = self; play.action = #selector(playMotion)
        sidebar.addArrangedSubview(play)
        sidebar.addArrangedSubview(label("Mouth opening"))
        mouth.target = self; mouth.action = #selector(changeMouth)
        mouth.isContinuous = true
        sidebar.addArrangedSubview(mouth)
        sidebar.addArrangedSubview(NSButton(title: "Reset pose & view", target: self, action: #selector(reset)))
        sidebar.addArrangedSubview(label("Move the mouse to look around.\nDrag to reposition. Scroll to zoom.", secondary: true))
        modelCredits = label("", size: 11, secondary: true)
        sidebar.addArrangedSubview(modelCredits)
        for control in [avatarPicker, expression, motions, mouth, voiceStatus, userCaption, assistantCaption, emotionPicker] as [NSView] {
            control.widthAnchor.constraint(equalTo: sidebar.widthAnchor).isActive = true
        }
        refreshModelControls()
        window.center()
        if show {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func refreshModelControls() {
        window.title = "Live2D Avatar · \(renderer.modelName)"
        chatWindow?.subtitle = renderer.avatar?.persona.name ?? renderer.modelName
        avatarPicker.selectedSegment = renderer.avatar.flatMap { availableAvatars.firstIndex(of: $0) } ?? -1
        modelLabel.stringValue = renderer.modelName.uppercased()
        modelStats.stringValue = "\(renderer.model.parameterCount) parameters\n\(renderer.model.drawableCount) drawable meshes"
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
        play.isEnabled = !motionItems.isEmpty
        mouth.doubleValue = 0
        emotionPicker.selectItem(withTitle: renderer.emotion?.title ?? "Manual pose")
        automaticEmotion.isEnabled = renderer.avatar != nil
        emotionPicker.isEnabled = renderer.avatar != nil
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

    @objc func toggleFollow(_ sender: NSButton) {
        defer { updateResponsesContext() }
        renderer.followsMouse = sender.state == .on
        renderer.model.dragX = 0; renderer.model.dragY = 0
    }
    @objc func togglePause(_ sender: NSButton) { renderer.paused = sender.state == .on; updateResponsesContext() }
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
        chatButton.title = chatIsVisible ? "Hide chat" : "Show chat"
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
        renderChat()
    }

    func receiveTranscript(_ fragment: LiveTranscript) {
        let name = renderer.avatar?.persona.name ?? renderer.modelName
        let text = String(((captionText[fragment.speaker] ?? "") + fragment.delta).suffix(1000))
        captionText[fragment.speaker] = text
        let caption = fragment.speaker == .user ? userCaption : assistantCaption
        caption.stringValue = "\(fragment.speaker == .user ? "You" : name): \(text.suffix(220))"
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
            clearChat()
            muteButton.state = .off
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
        if voice?.state == .connected {
            voiceStatus.stringValue = muteButton.state == .on ? "Voice connected · microphone muted" : "Voice connected · microphone live"
            syncChatStatus()
        }
    }

    func refreshVoiceControls(_ state: GPTLiveClient.State) {
        defer { syncChatStatus() }
        voiceButton.isEnabled = state != .closing
        muteButton.isEnabled = state == .connected
        switch state {
        case .idle: voiceStatus.stringValue = "Voice off"
        case .connecting:
            voiceButton.title = "Cancel voice"
            voiceStatus.stringValue = "Connecting…"
        case .connected:
            voiceButton.title = "Stop voice"
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
