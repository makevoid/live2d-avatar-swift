import AppKit
import Cubism
import ImageIO
import MetalKit
import AvatarBehavior

enum ViewerError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

struct ModelManifest: Decodable {
    struct References: Decodable {
        struct Expression: Decodable { let Name: String; let File: String }
        struct Motion: Decodable { let File: String }
        let Expressions: [Expression]?
        let Motions: [String: [Motion]]?
    }
    let FileReferences: References
}

enum BundledAvatar: Int, CaseIterable {
    case character, creature, sample

    var directoryName: String { self == .sample ? "Haru" : (self == .character ? "live2d_model" : "live2d_model_creature") }
    var title: String { self == .sample ? "Haru" : (self == .character ? "Character" : "Creature") }
    var manifestName: String {
        self == .sample ? "Haru.model3.json" : (self == .character ? "Bear Commander Belongs_to_DG_STUDIO.model3.json" : "F2U Red Panda.model3.json")
    }
    var modelName: String { persona.name }
    var persona: AvatarPersona { self == .sample ? .haru : (self == .character ? .commander : .poldo) }
    static func available(in resources: URL) -> [BundledAvatar] {
        allCases.filter { FileManager.default.fileExists(atPath: resources.appendingPathComponent($0.directoryName).appendingPathComponent($0.manifestName).path) }
    }
    var credits: String {
        if self == .sample { return "Haru © Live2D Inc. · Official SDK sample" }
        return self == .character ? "Model: Bear Commander · DG_STUDIO\nCreator: @KenKenMo6\n天才设计学家" : "Model: F2U Red Panda"
    }
}

final class AvatarRenderer: NSObject, MTKViewDelegate {
    // Upper-body framing matched to the user's reference screenshot.
    static let initialZoom = 2.15
    static let initialPanX = 0.05
    static let initialPanY = -1.235
    // Haru uses the same upper-body presentation, calibrated for her taller rig.
    static let haruZoom = 2.5
    static let haruPanX = 0.05
    static let haruPanY = -1.47
    // Smaller, lower framing matched to the creature reference screenshot.
    static let creatureZoom = 0.62
    static let creaturePanY = -0.15
    static let bearEarDrawables = ["ArtMesh11", "ArtMesh56", "ArtMesh304", "ArtMesh305"]
    let device: MTLDevice
    let queue: MTLCommandQueue
    private let landscape: LandscapeRenderer
    private(set) var model: Live2DUserModel!
    private(set) var manifest: ModelManifest!
    private(set) var modelDirectory: URL
    private(set) var avatar: BundledAvatar?
    private(set) var modelName = ""
    var zoom = AvatarRenderer.initialZoom
    var panX = AvatarRenderer.initialPanX
    var panY = AvatarRenderer.initialPanY
    var paused = false
    var followsMouse = false
    /// Desktop mode: omit scenery so only the avatar is drawn over a clear background.
    var transparent = false
    private var lastTime = CACurrentMediaTime()
    private var frameworkStarted = false
    private(set) var emotion: AvatarEmotion? = .happy
    var expressions: [AvatarExpression] {
        (manifest.FileReferences.Expressions ?? []).map { entry in
            avatar?.persona.expressions.first { $0.id == entry.Name } ??
                AvatarExpression(id: entry.Name, name: entry.Name, description: "Authored model expression.")
        }
    }
    private var emotionTime = 0.0
    private var emotionValues: [String: Double] = [:]
    private var emotionOffsets: [String: Double] = [:]
    private var emotionMultipliers: [String: Double] = [:]
    private var parameterRanges: [String: [String: NSNumber]] = [:]

    init(modelDirectory: URL, shaderDirectory: URL) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw ViewerError.message("This Mac does not expose a Metal device.")
        }
        self.device = device
        self.queue = queue
        landscape = try LandscapeRenderer(device: device)
        self.modelDirectory = modelDirectory
        let header = try String(contentsOf: shaderDirectory.appendingPathComponent("MetalShaderTypes.h"), encoding: .utf8)
        let source = try String(contentsOf: shaderDirectory.appendingPathComponent("MetalShaders.metal"), encoding: .utf8)
            .replacingOccurrences(of: "#include \"MetalShaderTypes.h\"", with: header)
        // Runtime compilation also works with Command Line Tools, without a downloaded Metal compiler.
        let library = try device.makeLibrary(source: source, options: nil)
        super.init()
        PlatformConfig.mtlDevice = device
        PlatformConfig.logHandler = { message in fputs("\(message)\n", stderr) }
        Live2DCubism.shared().start()
        frameworkStarted = true
        Live2DCubism.shared().setShaderLibrary(library)
        try loadModel(from: modelDirectory)
    }

    /// Called between frames; keep the framework/device alive and replace only the model.
    /// Prepare the replacement before committing so a load failure leaves the current avatar usable.
    func loadModel(from directory: URL) throws {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(".model3.json") }
        guard files.count == 1, let manifestURL = files.first else {
            throw ViewerError.message("Expected one .model3.json in \(directory.path)")
        }
        let nextManifest = try JSONDecoder().decode(ModelManifest.self, from: Data(contentsOf: manifestURL))
        let nextAvatar = BundledAvatar.allCases.first { $0.manifestName == manifestURL.lastPathComponent }
        let nextModel = try Live2DUserModel(homeDir: directory.path)
        if nextAvatar == .character {
            // Hide both the regular and hat-mounted ears without changing the purchased assets.
            for identifier in Self.bearEarDrawables {
                guard nextModel.setDrawable(identifier, hidden: true) else {
                    throw ViewerError.message("Cannot find bear-ear mesh \(identifier).")
                }
            }
        }
        // Both bundled avatars start in Smile, including when switched while paused.
        // Save the base parameter before updating so it persists through animation.
        if nextAvatar != nil, !nextModel.setParameter("ParamMouthForm", value: 1) {
            throw ViewerError.message("Cannot apply the default Smile pose to \(nextAvatar!.modelName).")
        }
        nextModel.update(deltaTime: 0)
        model = nextModel
        manifest = nextManifest
        modelDirectory = directory
        avatar = nextAvatar
        modelName = nextAvatar?.modelName ?? manifestURL.lastPathComponent.replacingOccurrences(of: ".model3.json", with: "")
        parameterRanges = nextModel.parameterRanges
        emotion = nextAvatar == nil ? nil : .happy
        emotionTime = 0
        emotionValues.removeAll(); emotionOffsets.removeAll(); emotionMultipliers.removeAll()
        resetView()
        lastTime = CACurrentMediaTime()
    }

    deinit {
        // Cubism IDs and allocator must outlive every model and renderer.
        model = nil
        if frameworkStarted { Live2DCubism.shared().stop() }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        defer { lastTime = now }
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let command = queue.makeCommandBuffer() else { return }
        if !paused { updateAnimation(deltaTime: now - lastTime) }
        do { try encode(command, pass: pass, size: view.drawableSize) }
        catch { fputs("Rendering failed: \(error.localizedDescription)\n", stderr); return }
        command.present(drawable)
        command.commit()
        // The upstream renderer rewrites shared vertex buffers each frame.
        // Serialize frames so the CPU cannot overwrite buffers still in use by the GPU.
        command.waitUntilCompleted()
    }

    private func encode(_ command: MTLCommandBuffer, pass: MTLRenderPassDescriptor, size: CGSize,
                        includesBackground: Bool = true) throws {
        let loadAction = pass.colorAttachments[0].loadAction
        defer { pass.colorAttachments[0].loadAction = loadAction }
        if avatar == .creature && includesBackground && !transparent {
            try landscape.encode(command, pass: pass, size: size)
            // Cubism draws in a second pass; preserve the landscape beneath it.
            pass.colorAttachments[0].loadAction = .load
        }
        model.render(commandBuffer: command, passDescriptor: pass,
                     width: size.width, height: size.height, zoom: zoom, panX: panX, panY: panY)
    }

    func reset() {
        resetView()
        clearEmotion()
        model.resetPose()
    }

    func setEmotion(_ next: AvatarEmotion, replay: Bool = false) {
        guard avatar != nil else { return }
        guard emotion != next || replay else { return }
        emotion = next
        emotionTime = 0
    }

    func clearEmotion() {
        emotion = nil
        emotionValues.removeAll(); emotionOffsets.removeAll(); emotionMultipliers.removeAll()
        model.setEmotion(values: [:], offsets: [:], multipliers: [:])
    }

    /// Same deterministic animation path used by the window and emotion verification.
    func updateAnimation(deltaTime: Double) {
        let delta = min(0.1, max(0, deltaTime))
        if let emotion {
            emotionTime += delta
            let pose = EmotionPose.sample(emotion, seconds: emotionTime, creature: avatar == .creature)
            let blend = 1 - exp(-delta * 9)
            func approach(_ targets: [String: Double], current: inout [String: Double], identity: Double?) {
                for (id, target) in targets where parameterRanges[id] != nil {
                    let start = current[id] ?? identity ?? model.parameterValue(for: id)
                    current[id] = start + (target - start) * blend
                }
            }
            approach(pose.values, current: &emotionValues, identity: nil)
            approach(pose.offsets, current: &emotionOffsets, identity: 0)
            approach(pose.multipliers, current: &emotionMultipliers, identity: 1)
            model.setEmotion(values: emotionValues.mapValues { NSNumber(value: $0) },
                             offsets: emotionOffsets.mapValues { NSNumber(value: $0) },
                             multipliers: emotionMultipliers.mapValues { NSNumber(value: $0) })
        }
        model.update(deltaTime: delta)
    }

    private func resetView() {
        switch avatar {
        case .character:
            (zoom, panX, panY) = (Self.initialZoom, Self.initialPanX, Self.initialPanY)
        case .creature:
            (zoom, panX, panY) = (Self.creatureZoom, 0, Self.creaturePanY)
        case .sample:
            (zoom, panX, panY) = (Self.haruZoom, Self.haruPanX, Self.haruPanY)
        case nil:
            (zoom, panX, panY) = (1, 0, 0)
        }
    }

    /// Render through the same Cubism/Metal pipeline as the window, then read the GPU output.
    func snapshot(width: Int = 900, height: Int = 1000, includesBackground: Bool = true) throws -> Data {
        let color = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        color.storageMode = .shared
        color.usage = [.renderTarget, .shaderRead]
        let depth = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: width, height: height, mipmapped: false)
        depth.storageMode = .private
        depth.usage = .renderTarget
        guard let texture = device.makeTexture(descriptor: color), let depthTexture = device.makeTexture(descriptor: depth),
              let command = queue.makeCommandBuffer() else { throw ViewerError.message("Cannot allocate snapshot textures.") }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        pass.depthAttachment.texture = depthTexture
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        pass.depthAttachment.clearDepth = 1
        try encode(command, pass: pass, size: CGSize(width: width, height: height), includesBackground: includesBackground)
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { throw command.error ?? ViewerError.message("Metal rendering failed.") }
        var pixels = Data(count: width * height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            texture.getBytes(bytes.baseAddress!, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        return pixels
    }

    func image(_ pixels: Data, width: Int = 900, height: Int = 1000) throws -> CGImage {
        guard let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue).union(.byteOrder32Little),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            throw ViewerError.message("Cannot create an image from rendered pixels.")
        }
        return image
    }

    func savePNG(_ pixels: Data, to url: URL, width: Int = 900, height: Int = 1000) throws {
        let image = try image(pixels, width: width, height: height)
        guard let target = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw ViewerError.message("Cannot create PNG at \(url.path)")
        }
        CGImageDestinationAddImage(target, image, nil)
        guard CGImageDestinationFinalize(target) else { throw ViewerError.message("Could not write PNG.") }
    }
}

final class AvatarMetalView: MTKView {
    weak var renderer: AvatarRenderer?
    /// In desktop mode dragging moves the frameless window; the avatar never pans or zooms.
    var movesWindow = false
    private var mouseArea: NSTrackingArea?
    override var acceptsFirstResponder: Bool { true }
    // The first click on an inactive floating window must start a window drag, not a pan.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { movesWindow }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let mouseArea { removeTrackingArea(mouseArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        mouseArea = area
    }
    override func mouseMoved(with event: NSEvent) {
        guard let renderer, renderer.followsMouse else { return }
        let point = convert(event.locationInWindow, from: nil)
        renderer.model.dragX = max(-1, min(1, point.x / max(bounds.width, 1) * 2 - 1))
        renderer.model.dragY = max(-1, min(1, point.y / max(bounds.height, 1) * 2 - 1))
    }
    override func mouseExited(with event: NSEvent) {
        renderer?.model.dragX = 0; renderer?.model.dragY = 0
    }
    override func mouseDown(with event: NSEvent) {
        // Outside desktop mode the press is kept here so it pans the avatar instead of reaching the window.
        if movesWindow { window?.performDrag(with: event) }
    }
    // A non-opaque view lets AppKit drag the window from its background; only desktop mode allows that.
    override var mouseDownCanMoveWindow: Bool { movesWindow }
    override func mouseDragged(with event: NSEvent) {
        guard let renderer, !movesWindow else { return }
        renderer.panX += event.deltaX / max(bounds.width, 1) * 2
        renderer.panY -= event.deltaY / max(bounds.height, 1) * 2
    }
    override func scrollWheel(with event: NSEvent) {
        guard let renderer, !movesWindow else { return }
        renderer.zoom = max(0.2, min(3, renderer.zoom * exp(-event.scrollingDeltaY * 0.01)))
    }
}
