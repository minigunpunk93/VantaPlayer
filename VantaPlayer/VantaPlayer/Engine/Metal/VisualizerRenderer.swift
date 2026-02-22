@preconcurrency import MetalKit
import QuartzCore
import simd

final class VisualizerRenderer: NSObject, MTKViewDelegate {
    struct PlaybackState {
        var isPlaying: Bool
        var playbackTime: TimeInterval
        var energy: Float
        var spectrum: [Float]
        var reduceMotion: Bool
    }

    private struct VisualizerUniforms {
        var time: Float
        var energy: Float
        var reducedMotion: Float
        var isPlaying: Float
        var size: SIMD2<Float>
        var spectrumCount: UInt32
        var padding: UInt32
    }

    typealias PlaybackStateProvider = () -> PlaybackState

    private static let maxSpectrumBins = 128
    private static let spectrumBufferCount = 3

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let playbackStateProvider: PlaybackStateProvider

    private var pipelineState: MTLRenderPipelineState?
    private var spectrumBuffers: [MTLBuffer] = []
    private var spectrumBufferIndex = 0
    private var startTime = CACurrentMediaTime()
    private var smoothedEnergy: Float = 0.12

    init?(device: MTLDevice, playbackStateProvider: @escaping PlaybackStateProvider) {
        guard let commandQueue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.commandQueue = commandQueue
        self.playbackStateProvider = playbackStateProvider
        super.init()

        let spectrumBufferLength = MemoryLayout<Float>.stride * Self.maxSpectrumBins
        for index in 0..<Self.spectrumBufferCount {
            guard let buffer = device.makeBuffer(length: spectrumBufferLength, options: .storageModeShared) else {
                return nil
            }
            buffer.label = "VantaPlayer.SpectrumBuffer.\(index)"
            spectrumBuffers.append(buffer)
        }
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
        let targetEnergy = max(0.02, min(playbackState.energy, 1))
        let smoothing: Float = playbackState.reduceMotion ? 0.09 : 0.22
        smoothedEnergy += (targetEnergy - smoothedEnergy) * smoothing

        let spectrumBuffer = spectrumBuffers[spectrumBufferIndex]
        spectrumBufferIndex = (spectrumBufferIndex + 1) % Self.spectrumBufferCount
        let spectrumCount = writeSpectrum(
            playbackState.spectrum,
            isPlaying: playbackState.isPlaying,
            time: elapsed,
            to: spectrumBuffer
        )

        var uniforms = VisualizerUniforms(
            time: elapsed,
            energy: smoothedEnergy,
            reducedMotion: playbackState.reduceMotion ? 1 : 0,
            isPlaying: playbackState.isPlaying ? 1 : 0,
            size: SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height)),
            spectrumCount: UInt32(spectrumCount),
            padding: 0
        )

        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<VisualizerUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<VisualizerUniforms>.stride, index: 0)
        encoder.setFragmentBuffer(spectrumBuffer, offset: 0, index: 1)
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

    private func writeSpectrum(
        _ sourceSpectrum: [Float],
        isPlaying: Bool,
        time: Float,
        to buffer: MTLBuffer
    ) -> Int {
        let destination = buffer.contents().bindMemory(to: Float.self, capacity: Self.maxSpectrumBins)
        destination.update(repeating: 0, count: Self.maxSpectrumBins)

        let clampedCount = max(1, min(sourceSpectrum.count, Self.maxSpectrumBins))
        for index in 0..<clampedCount {
            let normalized = max(0, min(sourceSpectrum[index], 1))
            destination[index] = normalized
        }

        // Keep a gentle baseline when idle so the scene never hard-snaps to zero.
        if !isPlaying {
            for index in 0..<clampedCount {
                let x = Float(index) / Float(max(clampedCount - 1, 1))
                let baseline = 0.01 + (0.01 * sin((x * 11.0) + (time * 0.45)))
                destination[index] = max(destination[index] * 0.28, baseline)
            }
        }

        return clampedCount
    }
}
