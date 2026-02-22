@preconcurrency import MetalKit
import QuartzCore
import simd

final class VisualizerRenderer: NSObject, MTKViewDelegate {
    struct PlaybackState {
        var isPlaying: Bool
        var playbackTime: TimeInterval
        var energy: Float
        var reduceMotion: Bool
    }

    private struct VisualizerUniforms {
        var time: Float
        var energy: Float
        var reduceMotion: Float
        var size: SIMD2<Float>
    }

    typealias PlaybackStateProvider = () -> PlaybackState

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let playbackStateProvider: PlaybackStateProvider

    private var pipelineState: MTLRenderPipelineState?
    private var startTime = CACurrentMediaTime()
    private var smoothedEnergy: Float = 0.22

    init?(device: MTLDevice, playbackStateProvider: @escaping PlaybackStateProvider) {
        guard let commandQueue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.commandQueue = commandQueue
        self.playbackStateProvider = playbackStateProvider
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor else {
            return
        }

        if pipelineState == nil {
            pipelineState = makePipelineState(for: view)
        }

        guard let pipelineState,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        let playbackState = playbackStateProvider()
        let elapsed = Float(CACurrentMediaTime() - startTime)
        let idlePulse = 0.18 + (0.08 * sin(elapsed * (playbackState.reduceMotion ? 0.35 : 0.78)))
        let playbackPulse = playbackState.isPlaying
            ? (0.16 * sin(Float(playbackState.playbackTime) * 4.0))
            : 0

        let targetEnergy = max(0.05, min(playbackState.energy + idlePulse + playbackPulse, 1))
        let smoothing: Float = playbackState.reduceMotion ? 0.05 : 0.14
        smoothedEnergy += (targetEnergy - smoothedEnergy) * smoothing

        var uniforms = VisualizerUniforms(
            time: elapsed,
            energy: smoothedEnergy,
            reduceMotion: playbackState.reduceMotion ? 1 : 0,
            size: SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height))
        )

        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<VisualizerUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<VisualizerUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func makePipelineState(for view: MTKView) -> MTLRenderPipelineState? {
        guard let library = device.makeDefaultLibrary(),
              let vertexFunction = library.makeFunction(name: "vanta_vertex"),
              let fragmentFunction = library.makeFunction(name: "vanta_fragment") else {
            return nil
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "VantaPlayer.VisualizerPipeline"
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat

        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }
}
