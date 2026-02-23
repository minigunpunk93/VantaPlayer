@preconcurrency import MetalKit
import QuartzCore
import simd

final class RibbonRenderer: NSObject, MTKViewDelegate {
    struct PlaybackState {
        var isPlaying: Bool
        var playbackTime: TimeInterval
        var reduceMotion: Bool
        var spectrumStore: SpectrumStore?
    }

    private struct RibbonUniforms {
        var time: Float
        var energy: Float
        var reducedMotion: Float
        var isPlaying: Float
        var size: SIMD2<Float>
        var spectrumCount: UInt32
        var debugFPS: Float
    }

    typealias PlaybackStateProvider = () -> PlaybackState

    private static let spectrumBufferCount = 3
    private static let maxSpectrumBins = 256

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let playbackStateProvider: PlaybackStateProvider

    private var pipelineState: MTLRenderPipelineState?
    private var spectrumBuffers: [MTLBuffer] = []
    private var spectrumBufferIndex = 0
    private var startTime = CACurrentMediaTime()
    private var smoothedEnergy: Float = 0.08

    #if DEBUG
    private let showFPSCounter: Bool
    private var fpsFrameCount = 0
    private var fpsSampleStart = CACurrentMediaTime()
    private var latestFPS: Float = 0
    #endif

    #if DEBUG
    init?(device: MTLDevice, showFPSCounter: Bool = false, playbackStateProvider: @escaping PlaybackStateProvider) {
        self.showFPSCounter = showFPSCounter
        guard let commandQueue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.commandQueue = commandQueue
        self.playbackStateProvider = playbackStateProvider
        super.init()

        guard makeSpectrumBuffers() else { return nil }
    }
    #else
    init?(device: MTLDevice, playbackStateProvider: @escaping PlaybackStateProvider) {
        guard let commandQueue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.commandQueue = commandQueue
        self.playbackStateProvider = playbackStateProvider
        super.init()

        guard makeSpectrumBuffers() else { return nil }
    }
    #endif

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

        let now = CACurrentMediaTime()
        let elapsed = Float(now - startTime)
        let playbackState = playbackStateProvider()

        let spectrumBuffer = spectrumBuffers[spectrumBufferIndex]
        spectrumBufferIndex = (spectrumBufferIndex + 1) % Self.spectrumBufferCount

        let spectrumSnapshot = writeSpectrum(
            playbackState: playbackState,
            time: elapsed,
            to: spectrumBuffer
        )

        let targetEnergy = max(0.03, min(spectrumSnapshot.energy, 1))
        let smoothFactor: Float = playbackState.isPlaying
            ? (playbackState.reduceMotion ? 0.09 : 0.24)
            : (playbackState.reduceMotion ? 0.05 : 0.14)
        smoothedEnergy += (targetEnergy - smoothedEnergy) * smoothFactor

        #if DEBUG
        if showFPSCounter {
            fpsFrameCount += 1
            let sampleDuration = now - fpsSampleStart
            if sampleDuration >= 1.0 {
                latestFPS = Float(Double(fpsFrameCount) / sampleDuration)
                fpsFrameCount = 0
                fpsSampleStart = now
            }
        }
        let debugFPS = showFPSCounter ? latestFPS : 0
        #else
        let debugFPS: Float = 0
        #endif

        var uniforms = RibbonUniforms(
            time: elapsed,
            energy: smoothedEnergy,
            reducedMotion: playbackState.reduceMotion ? 1 : 0,
            isPlaying: playbackState.isPlaying ? 1 : 0,
            size: SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height)),
            spectrumCount: UInt32(spectrumSnapshot.count),
            debugFPS: debugFPS
        )

        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<RibbonUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<RibbonUniforms>.stride, index: 0)
        encoder.setFragmentBuffer(spectrumBuffer, offset: 0, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func makeSpectrumBuffers() -> Bool {
        let spectrumBufferLength = MemoryLayout<Float>.stride * Self.maxSpectrumBins

        for index in 0..<Self.spectrumBufferCount {
            guard let buffer = device.makeBuffer(length: spectrumBufferLength, options: .storageModeShared) else {
                return false
            }
            buffer.label = "VantaPlayer.RibbonSpectrumBuffer.\(index)"
            spectrumBuffers.append(buffer)
        }

        return true
    }

    private func makePipelineState(for view: MTKView) -> MTLRenderPipelineState? {
        guard let library = device.makeDefaultLibrary(),
              let vertexFunction = library.makeFunction(name: "ribbon_vertex"),
              let fragmentFunction = library.makeFunction(name: "ribbon_fragment") else {
            return nil
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "VantaPlayer.RibbonPipeline"
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat

        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    private func writeSpectrum(
        playbackState: PlaybackState,
        time: Float,
        to buffer: MTLBuffer
    ) -> SpectrumStore.Snapshot {
        let destination = buffer.contents().bindMemory(to: Float.self, capacity: Self.maxSpectrumBins)
        let snapshot: SpectrumStore.Snapshot
        if let spectrumStore = playbackState.spectrumStore {
            snapshot = spectrumStore.copySpectrum(into: destination, capacity: Self.maxSpectrumBins)
        } else {
            destination.update(repeating: 0, count: Self.maxSpectrumBins)
            snapshot = SpectrumStore.Snapshot(count: Self.maxSpectrumBins, energy: 0)
        }

        let count = max(1, min(snapshot.count, Self.maxSpectrumBins))
        for index in 0..<count {
            let x = Float(index) / Float(max(count - 1, 1))
            let motion: Float = playbackState.reduceMotion ? 0.32 : 1.0
            let phaseLeft: Float = x * 9.3
            let phaseRight: Float = (time * 0.42) * motion
            let phase: Float = phaseLeft + phaseRight
            let idleRipple: Float = 0.018 + (0.009 * sinf(phase))

            let clamped = max(0, min(destination[index], 1))
            if playbackState.isPlaying {
                destination[index] = max(clamped, 0.014)
            } else {
                destination[index] = max(clamped * 0.26, idleRipple)
            }
        }

        if count < Self.maxSpectrumBins {
            destination.advanced(by: count).update(repeating: 0, count: Self.maxSpectrumBins - count)
        }

        return SpectrumStore.Snapshot(count: count, energy: snapshot.energy)
    }
}
