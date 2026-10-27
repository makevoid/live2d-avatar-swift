import CoreGraphics
import MetalKit

/// The creature's scenery: draw vector layers once per size, then composite in Metal.
/// Coordinates in the drawing helpers run from 0...1, with the sky at y = 0.
final class LandscapeRenderer {
    private let device: MTLDevice
    private let pipeline: MTLRenderPipelineState
    private var texture: MTLTexture?

    init(device: MTLDevice) throws {
        self.device = device
        let library = try device.makeLibrary(source: """
            #include <metal_stdlib>
            using namespace metal;
            struct BackgroundVertex {
                float4 position [[position]];
                float2 uv;
            };
            vertex BackgroundVertex landscapeVertex(uint id [[vertex_id]]) {
                const float2 positions[] = {float2(-1, -1), float2(3, -1), float2(-1, 3)};
                float2 p = positions[id];
                return {float4(p, 0, 1), float2((p.x + 1) * 0.5, (1 - p.y) * 0.5)};
            }
            fragment float4 landscapeFragment(BackgroundVertex input [[stage_in]],
                                               texture2d<float> scene [[texture(0)]]) {
                constexpr sampler filtering(coord::normalized, address::clamp_to_edge, filter::linear);
                return scene.sample(filtering, input.uv);
            }
            """, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "Creature landscape"
        descriptor.vertexFunction = library.makeFunction(name: "landscapeVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "landscapeFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.depthAttachmentPixelFormat = .depth32Float
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    }

    func encode(_ command: MTLCommandBuffer, pass: MTLRenderPassDescriptor, size: CGSize) throws {
        let width = max(1, Int(size.width)), height = max(1, Int(size.height))
        if texture?.width != width || texture?.height != height {
            let image = try drawLandscape(width: width, height: height)
            texture = try MTKTextureLoader(device: device).newTexture(cgImage: image, options: [
                .SRGB: false, .origin: MTKTextureLoader.Origin.topLeft,
                .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue)
            ])
        }
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
            throw ViewerError.message("Cannot create landscape render pass.")
        }
        encoder.label = "Sky, mountains, meadow, ground"
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    private func drawLandscape(width: Int, height: Int) throws -> CGImage {
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ViewerError.message("Cannot allocate landscape image.")
        }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: CGFloat(width), y: -CGFloat(height))
        drawSky(in: context, aspect: CGFloat(width) / CGFloat(height))
        drawMountains(in: context)
        drawMeadow(in: context)
        drawGround(in: context)
        guard let image = context.makeImage() else { throw ViewerError.message("Cannot draw landscape.") }
        return image
    }

    private func drawSky(in context: CGContext, aspect: CGFloat) {
        gradient(in: context, from: color(0.56, 0.77, 0.88), to: color(0.92, 0.95, 0.88), top: 0, bottom: 0.67)
        // A pale sun and a few soft, broad clouds leave the center uncluttered.
        context.setFillColor(color(1.0, 0.97, 0.79))
        context.fillEllipse(in: CGRect(x: 0.76, y: 0.12, width: 0.09 / aspect, height: 0.09))
        context.setFillColor(color(1.0, 0.99, 0.95, 0.65))
        for cloud in [CGRect(x: 0.06, y: 0.20, width: 0.22, height: 0.035),
                      CGRect(x: 0.16, y: 0.18, width: 0.10, height: 0.045),
                      CGRect(x: 0.51, y: 0.27, width: 0.20, height: 0.026),
                      CGRect(x: 0.57, y: 0.25, width: 0.09, height: 0.04)] {
            context.fillEllipse(in: cloud)
        }
    }

    private func drawMountains(in context: CGContext) {
        fill(in: context, points: [(-0.05, 0.62), (0.08, 0.44), (0.19, 0.52), (0.36, 0.31),
                                  (0.53, 0.52), (0.68, 0.38), (0.85, 0.54), (1.04, 0.41),
                                  (1.04, 0.74), (-0.05, 0.74)], color: color(0.59, 0.73, 0.75))
        fill(in: context, points: [(0.19, 0.52), (0.36, 0.31), (0.31, 0.51), (0.43, 0.65)],
             color: color(0.49, 0.65, 0.69))
        fill(in: context, points: [(0.53, 0.52), (0.68, 0.38), (0.62, 0.60)], color: color(0.49, 0.65, 0.69))
        fill(in: context, points: [(0.29, 0.397), (0.36, 0.31), (0.44, 0.409),
                                  (0.38, 0.388), (0.351, 0.412), (0.331, 0.391)],
             color: color(0.92, 0.95, 0.90))
        fill(in: context, points: [(0.635, 0.422), (0.68, 0.38), (0.733, 0.43),
                                  (0.686, 0.417), (0.667, 0.433)], color: color(0.88, 0.93, 0.89))
    }

    private func drawMeadow(in context: CGContext) {
        let far = CGMutablePath()
        far.move(to: CGPoint(x: 0, y: 0.61))
        far.addCurve(to: CGPoint(x: 1, y: 0.64), control1: CGPoint(x: 0.35, y: 0.47), control2: CGPoint(x: 0.62, y: 0.71))
        closeToBottom(far)
        context.addPath(far)
        context.setFillColor(color(0.48, 0.66, 0.45))
        context.fillPath()

        let near = CGMutablePath()
        near.move(to: CGPoint(x: 0, y: 0.69))
        near.addCurve(to: CGPoint(x: 1, y: 0.61), control1: CGPoint(x: 0.38, y: 0.78), control2: CGPoint(x: 0.60, y: 0.53))
        closeToBottom(near)
        context.saveGState()
        context.addPath(near)
        context.clip()
        gradient(in: context, from: color(0.57, 0.71, 0.40), to: color(0.39, 0.58, 0.31), top: 0.57, bottom: 0.95)
        context.restoreGState()
    }

    private func drawGround(in context: CGContext) {
        let ground = CGMutablePath()
        ground.move(to: CGPoint(x: 0, y: 0.82))
        ground.addCurve(to: CGPoint(x: 1, y: 0.82), control1: CGPoint(x: 0.33, y: 0.77), control2: CGPoint(x: 0.67, y: 0.77))
        closeToBottom(ground)
        context.saveGState()
        context.addPath(ground)
        context.clip()
        gradient(in: context, from: color(0.79, 0.74, 0.52), to: color(0.67, 0.61, 0.40), top: 0.78, bottom: 1)
        // Sparse marks keep the foreground legible without competing with the avatar.
        context.setStrokeColor(color(0.50, 0.59, 0.32, 0.65))
        context.setLineWidth(0.0015)
        context.setLineCap(.round)
        for (x, y) in [(0.09, 0.86), (0.18, 0.94), (0.32, 0.88), (0.74, 0.91), (0.87, 0.84), (0.94, 0.96)] {
            context.move(to: CGPoint(x: x - 0.006, y: y))
            context.addLine(to: CGPoint(x: x - 0.009, y: y - 0.01))
            context.move(to: CGPoint(x: x, y: y))
            context.addLine(to: CGPoint(x: x + 0.002, y: y - 0.013))
            context.strokePath()
        }
        context.restoreGState()
    }

    private func closeToBottom(_ path: CGMutablePath) {
        path.addLine(to: CGPoint(x: 1, y: 1))
        path.addLine(to: CGPoint(x: 0, y: 1))
        path.closeSubpath()
    }

    private func fill(in context: CGContext, points: [(CGFloat, CGFloat)], color: CGColor) {
        guard let first = points.first else { return }
        context.move(to: CGPoint(x: first.0, y: first.1))
        for point in points.dropFirst() { context.addLine(to: CGPoint(x: point.0, y: point.1)) }
        context.closePath()
        context.setFillColor(color)
        context.fillPath()
    }

    private func gradient(in context: CGContext, from: CGColor, to: CGColor, top: CGFloat, bottom: CGFloat) {
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [from, to] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: top), end: CGPoint(x: 0, y: bottom),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    private func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(red: red, green: green, blue: blue, alpha: alpha)
    }
}
