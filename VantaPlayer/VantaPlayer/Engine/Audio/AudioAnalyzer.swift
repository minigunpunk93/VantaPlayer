import Accelerate
import AVFoundation
import Combine
import Foundation
import QuartzCore

final class AudioAnalyzer: ObservableObject {
    struct AnalysisFrame: Sendable {
        var spectrum: [Float]
        var energy: Float
    }

    static let defaultFFTSize = 2048
    static let defaultHopSize = 512
    static let defaultOutputBinCount = 96

    @Published private(set) var spectrum: [Float]
    @Published private(set) var energy: Float = 0

    private let fftSize: Int
    private let hopSize: Int
    private let outputBinCount: Int
    private let publishInterval: CFTimeInterval
    private let analysisQueue = DispatchQueue(label: "VantaPlayer.AudioAnalyzer", qos: .userInitiated)
    private let outputLock = NSLock()

    private var tapNode: AVAudioNode?
    private var tapBus: AVAudioNodeBus = 0
    private var fftSetup: FFTSetup?
    private var log2n: vDSP_Length
    private var binRanges: [Range<Int>]
    private var window: [Float]
    private var ringBuffer: [Float]
    private var fftInput: [Float]
    private var splitReal: [Float]
    private var splitImag: [Float]
    private var magnitudes: [Float]
    private var thresholdedMagnitudes: [Float]
    private var decibels: [Float]
    private var collapsedBins: [Float]
    private var smoothedBins: [Float]
    private var sampleCursor = 0
    private var hopSampleCounter = 0
    private var lastPublishTime: CFTimeInterval = 0
    private var latestFrameStorage: AnalysisFrame

    init(
        fftSize: Int = AudioAnalyzer.defaultFFTSize,
        hopSize: Int = AudioAnalyzer.defaultHopSize,
        outputBinCount: Int = AudioAnalyzer.defaultOutputBinCount,
        targetFPS: Int = 60
    ) {
        let resolvedFFTSize = max(1024, fftSize.nonzeroPowerOfTwo)
        let resolvedHopSize = max(128, min(hopSize, resolvedFFTSize / 2))
        let resolvedOutputBins = max(16, min(outputBinCount, resolvedFFTSize / 2))

        self.fftSize = resolvedFFTSize
        self.hopSize = resolvedHopSize
        self.outputBinCount = resolvedOutputBins
        self.publishInterval = 1.0 / CFTimeInterval(max(1, targetFPS))
        self.log2n = vDSP_Length(log2(Double(resolvedFFTSize)))
        self.binRanges = AudioAnalyzer.makeLogBinRanges(
            fftBinCount: resolvedFFTSize / 2,
            outputBinCount: resolvedOutputBins
        )
        self.window = [Float](repeating: 0, count: resolvedFFTSize)
        self.ringBuffer = [Float](repeating: 0, count: resolvedFFTSize)
        self.fftInput = [Float](repeating: 0, count: resolvedFFTSize)
        self.splitReal = [Float](repeating: 0, count: resolvedFFTSize / 2)
        self.splitImag = [Float](repeating: 0, count: resolvedFFTSize / 2)
        self.magnitudes = [Float](repeating: 0, count: resolvedFFTSize / 2)
        self.thresholdedMagnitudes = [Float](repeating: 0, count: resolvedFFTSize / 2)
        self.decibels = [Float](repeating: 0, count: resolvedFFTSize / 2)
        self.collapsedBins = [Float](repeating: 0, count: resolvedOutputBins)
        self.smoothedBins = [Float](repeating: 0, count: resolvedOutputBins)
        self.spectrum = [Float](repeating: 0, count: resolvedOutputBins)
        self.latestFrameStorage = AnalysisFrame(
            spectrum: [Float](repeating: 0, count: resolvedOutputBins),
            energy: 0
        )

        vDSP_hann_window(&window, vDSP_Length(resolvedFFTSize), Int32(vDSP_HANN_NORM))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
    }

    deinit {
        removeTap()
        if let fftSetup {
            vDSP_destroy_fftsetup(fftSetup)
        }
    }

    func installTap(on node: AVAudioNode, bus: AVAudioNodeBus = 0, bufferSize: AVAudioFrameCount? = nil) {
        removeTap()
        tapNode = node
        tapBus = bus

        let requestedBufferSize = bufferSize ?? AVAudioFrameCount(hopSize)
        node.installTap(onBus: bus, bufferSize: requestedBufferSize, format: nil) { [weak self] buffer, _ in
            self?.analyze(buffer: buffer)
        }
    }

    func removeTap() {
        guard let tapNode else { return }
        tapNode.removeTap(onBus: tapBus)
        self.tapNode = nil
    }

    func reset() {
        analysisQueue.async { [weak self] in
            guard let self else { return }
            self.ringBuffer = [Float](repeating: 0, count: self.fftSize)
            self.fftInput = [Float](repeating: 0, count: self.fftSize)
            self.collapsedBins = [Float](repeating: 0, count: self.outputBinCount)
            self.smoothedBins = [Float](repeating: 0, count: self.outputBinCount)
            self.sampleCursor = 0
            self.hopSampleCounter = 0
            self.lastPublishTime = 0
            self.storeLatestFrame(AnalysisFrame(spectrum: self.smoothedBins, energy: 0))

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.spectrum = self.smoothedBins
                self.energy = 0
            }
        }
    }

    func latestFrame() -> AnalysisFrame {
        outputLock.lock()
        let frame = latestFrameStorage
        outputLock.unlock()
        return frame
    }

    private func analyze(buffer: AVAudioPCMBuffer) {
        analysisQueue.async { [weak self] in
            self?.ingest(buffer: buffer)
        }
    }

    private func ingest(buffer: AVAudioPCMBuffer) {
        guard let fftSetup,
              let channelData = buffer.floatChannelData else {
            return
        }

        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        guard channelCount > 0, frameLength > 0 else { return }

        for frame in 0..<frameLength {
            var monoSample: Float = 0
            for channel in 0..<channelCount {
                monoSample += channelData[channel][frame]
            }
            monoSample /= Float(channelCount)

            ringBuffer[sampleCursor] = monoSample
            sampleCursor = (sampleCursor + 1) % fftSize
            hopSampleCounter += 1

            if hopSampleCounter >= hopSize {
                hopSampleCounter -= hopSize
                processCurrentWindow(fftSetup: fftSetup)
            }
        }
    }

    private func processCurrentWindow(fftSetup: FFTSetup) {
        copyRingBufferIntoFFTInput()
        applyWindow()
        performFFT(fftSetup: fftSetup)
        collapseFFTToDisplayBins()
        smoothSpectrum()

        let frame = AnalysisFrame(
            spectrum: smoothedBins,
            energy: computeEnergy(from: smoothedBins)
        )
        storeLatestFrame(frame)

        let now = CACurrentMediaTime()
        guard (now - lastPublishTime) >= publishInterval else { return }
        lastPublishTime = now

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.spectrum = frame.spectrum
            self.energy = frame.energy
        }
    }

    private func copyRingBufferIntoFFTInput() {
        if sampleCursor == 0 {
            fftInput = ringBuffer
            return
        }

        let tailCount = fftSize - sampleCursor
        fftInput[0..<tailCount] = ringBuffer[sampleCursor..<fftSize]
        fftInput[tailCount..<fftSize] = ringBuffer[0..<sampleCursor]
    }

    private func applyWindow() {
        vDSP_vmul(fftInput, 1, window, 1, &fftInput, 1, vDSP_Length(fftSize))
    }

    private func performFFT(fftSetup: FFTSetup) {
        splitReal.withUnsafeMutableBufferPointer { realPointer in
            splitImag.withUnsafeMutableBufferPointer { imagPointer in
                var splitComplex = DSPSplitComplex(
                    realp: realPointer.baseAddress!,
                    imagp: imagPointer.baseAddress!
                )

                fftInput.withUnsafeMutableBufferPointer { inputPointer in
                    inputPointer.baseAddress!.withMemoryRebound(
                        to: DSPComplex.self,
                        capacity: fftSize / 2
                    ) { complexPointer in
                        vDSP_ctoz(complexPointer, 2, &splitComplex, 1, vDSP_Length(fftSize / 2))
                        vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))

                        var scale = Float(1.0 / Float(fftSize))
                        vDSP_vsmul(splitComplex.realp, 1, &scale, splitComplex.realp, 1, vDSP_Length(fftSize / 2))
                        vDSP_vsmul(splitComplex.imagp, 1, &scale, splitComplex.imagp, 1, vDSP_Length(fftSize / 2))
                        vDSP_zvabs(&splitComplex, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))
                    }
                }
            }
        }
    }

    private func collapseFFTToDisplayBins() {
        var floorMagnitude: Float = 1e-7
        let binCount = vDSP_Length(magnitudes.count)

        thresholdedMagnitudes = magnitudes
        thresholdedMagnitudes.withUnsafeBufferPointer { source in
            decibels.withUnsafeMutableBufferPointer { destination in
                guard let sourceBase = source.baseAddress,
                      let destinationBase = destination.baseAddress else {
                    return
                }
                vDSP_vthr(sourceBase, 1, &floorMagnitude, destinationBase, 1, binCount)
            }
        }

        var reference: Float = 1
        decibels.withUnsafeBufferPointer { source in
            thresholdedMagnitudes.withUnsafeMutableBufferPointer { destination in
                guard let sourceBase = source.baseAddress,
                      let destinationBase = destination.baseAddress else {
                    return
                }
                vDSP_vdbcon(sourceBase, 1, &reference, destinationBase, 1, binCount, 0)
            }
        }

        for (index, range) in binRanges.enumerated() {
            guard !range.isEmpty else {
                collapsedBins[index] = 0
                continue
            }

            let sum = range.reduce(Float.zero) { partialResult, binIndex in
                partialResult + thresholdedMagnitudes[binIndex]
            }
            let averageDB = sum / Float(range.count)
            let normalized = max(0, min((averageDB + 84) / 72, 1))
            collapsedBins[index] = normalized
        }
    }

    private func smoothSpectrum() {
        for index in 0..<collapsedBins.count {
            let target = collapsedBins[index]
            let current = smoothedBins[index]
            let coefficient: Float = target > current ? 0.44 : 0.14
            smoothedBins[index] = current + ((target - current) * coefficient)
        }
    }

    private func computeEnergy(from spectrum: [Float]) -> Float {
        guard !spectrum.isEmpty else { return 0 }
        let mean = spectrum.reduce(Float.zero, +) / Float(spectrum.count)
        return max(0, min(pow(mean, 0.85), 1))
    }

    private func storeLatestFrame(_ frame: AnalysisFrame) {
        outputLock.lock()
        latestFrameStorage = frame
        outputLock.unlock()
    }

    private static func makeLogBinRanges(fftBinCount: Int, outputBinCount: Int) -> [Range<Int>] {
        let minBin = 2
        let maxBin = max(minBin + 1, fftBinCount - 1)
        let minLog = log10(Float(minBin))
        let maxLog = log10(Float(maxBin))

        return (0..<outputBinCount).map { index in
            let lowT = Float(index) / Float(outputBinCount)
            let highT = Float(index + 1) / Float(outputBinCount)
            let low = Int(pow(10, minLog + ((maxLog - minLog) * lowT)))
            let high = Int(pow(10, minLog + ((maxLog - minLog) * highT)))
            let clampedLow = max(minBin, min(maxBin, low))
            let clampedHigh = max(clampedLow + 1, min(maxBin + 1, high))
            return clampedLow..<clampedHigh
        }
    }
}

private extension Int {
    var nonzeroPowerOfTwo: Int {
        guard self > 0 else { return 1024 }
        return 1 << Int(ceil(log2(Double(self))))
    }
}
