import Accelerate
import AVFoundation
import Foundation
import QuartzCore

final class AudioAnalyzer {
    static let defaultFFTSize = 2048
    static let defaultHopSize = 512
    static let defaultOutputBinCount = 256

    let spectrumStore: SpectrumStore

    private let fftSize: Int
    private let hopSize: Int
    private let analysisQueue = DispatchQueue(label: "VantaPlayer.AudioAnalyzer", qos: .userInitiated)

    private let minDecibels: Float = -80
    private let maxDecibels: Float = 0
    private let mappingGamma: Float = 0.62
    private let mappingGain: Float = 1.95

    private let attackTime: Float = 0.024
    private let releaseTime: Float = 0.16
    private let energyAttackTime: Float = 0.055
    private let energyReleaseTime: Float = 0.28

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
    private var decibels: [Float]
    private var collapsedBins: [Float]
    private var smoothedBins: [Float]

    private var sampleCursor = 0
    private var hopSampleCounter = 0
    private var smoothedEnergy: Float = 0
    private var lastSmoothingTimestamp: CFTimeInterval = 0

    init(
        fftSize: Int = AudioAnalyzer.defaultFFTSize,
        hopSize: Int = AudioAnalyzer.defaultHopSize,
        outputBinCount: Int = AudioAnalyzer.defaultOutputBinCount,
        spectrumStore: SpectrumStore? = nil
    ) {
        let resolvedFFTSize = max(1024, fftSize.nonzeroPowerOfTwo)
        let resolvedHopSize = max(128, min(hopSize, resolvedFFTSize / 2))
        let resolvedOutputBins = max(64, min(outputBinCount, resolvedFFTSize / 2))

        self.fftSize = resolvedFFTSize
        self.hopSize = resolvedHopSize
        self.spectrumStore = spectrumStore ?? SpectrumStore(binCount: resolvedOutputBins)
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
        self.decibels = [Float](repeating: 0, count: resolvedFFTSize / 2)
        self.collapsedBins = [Float](repeating: 0, count: resolvedOutputBins)
        self.smoothedBins = [Float](repeating: 0, count: resolvedOutputBins)

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
            self.ringBuffer.withUnsafeMutableBufferPointer { pointer in
                pointer.baseAddress?.update(repeating: 0, count: pointer.count)
            }
            self.fftInput.withUnsafeMutableBufferPointer { pointer in
                pointer.baseAddress?.update(repeating: 0, count: pointer.count)
            }
            self.collapsedBins.withUnsafeMutableBufferPointer { pointer in
                pointer.baseAddress?.update(repeating: 0, count: pointer.count)
            }
            self.smoothedBins.withUnsafeMutableBufferPointer { pointer in
                pointer.baseAddress?.update(repeating: 0, count: pointer.count)
            }
            self.sampleCursor = 0
            self.hopSampleCounter = 0
            self.smoothedEnergy = 0
            self.lastSmoothingTimestamp = 0
            self.spectrumStore.reset()
        }
    }

    func latestEnergy() -> Float {
        spectrumStore.latestEnergy()
    }

    private func analyze(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }

        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        guard channelCount > 0, frameLength > 0 else { return }

        // Copy/mix samples quickly from the tap callback, then process on the analysis queue.
        var monoSamples = [Float](repeating: 0, count: frameLength)
        for frame in 0..<frameLength {
            var mixed: Float = 0
            for channel in 0..<channelCount {
                mixed += channelData[channel][frame]
            }
            monoSamples[frame] = mixed / Float(channelCount)
        }

        analysisQueue.async { [weak self] in
            self?.ingest(samples: monoSamples)
        }
    }

    private func ingest(samples: [Float]) {
        guard let fftSetup else { return }

        for sample in samples {
            ringBuffer[sampleCursor] = sample
            sampleCursor = (sampleCursor + 1) % fftSize
            hopSampleCounter += 1

            if hopSampleCounter >= hopSize {
                hopSampleCounter -= hopSize
                processCurrentWindow(fftSetup: fftSetup)
            }
        }
    }

    private func processCurrentWindow(fftSetup: FFTSetup) {
        let deltaTime = nextDeltaTime()

        copyRingBufferIntoFFTInput()
        applyWindow()
        performFFT(fftSetup: fftSetup)
        collapseFFTToDisplayBins()
        smoothSpectrum(deltaTime: deltaTime)

        let energy = updateEnergy(deltaTime: deltaTime)
        spectrumStore.write(spectrum: smoothedBins, energy: energy)
    }

    private func nextDeltaTime() -> Float {
        let now = CACurrentMediaTime()
        defer { lastSmoothingTimestamp = now }

        guard lastSmoothingTimestamp > 0 else {
            return Float(hopSize) / 48_000
        }

        let rawDelta = now - lastSmoothingTimestamp
        return max(1 / 240, min(Float(rawDelta), 0.25))
    }

    private func copyRingBufferIntoFFTInput() {
        if sampleCursor == 0 {
            fftInput = ringBuffer
            return
        }

        let tailCount = fftSize - sampleCursor
        for index in 0..<tailCount {
            fftInput[index] = ringBuffer[sampleCursor + index]
        }
        for index in 0..<sampleCursor {
            fftInput[tailCount + index] = ringBuffer[index]
        }
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
        let dbFloor: Float = 1e-7
        for index in magnitudes.indices {
            let clampedMagnitude = max(magnitudes[index], dbFloor)
            let decibel = 20 * log10(clampedMagnitude)
            decibels[index] = min(max(decibel, minDecibels), maxDecibels)
        }

        let decibelRange = maxDecibels - minDecibels
        for (index, range) in binRanges.enumerated() {
            guard !range.isEmpty else {
                collapsedBins[index] = 0
                continue
            }

            var sum: Float = 0
            var peak = minDecibels
            for binIndex in range {
                let value = decibels[binIndex]
                sum += value
                peak = max(peak, value)
            }

            let average = sum / Float(range.count)
            let weightedDB = (peak * 0.68) + (average * 0.32)
            let normalized = max(0, min((weightedDB - minDecibels) / decibelRange, 1))
            let shaped = pow(normalized, mappingGamma)
            collapsedBins[index] = max(0, min(shaped * mappingGain, 1))
        }
    }

    private func smoothSpectrum(deltaTime: Float) {
        let attackCoefficient = smoothingCoefficient(timeConstant: attackTime, deltaTime: deltaTime)
        let releaseCoefficient = smoothingCoefficient(timeConstant: releaseTime, deltaTime: deltaTime)

        for index in collapsedBins.indices {
            let target = collapsedBins[index]
            let current = smoothedBins[index]
            let coefficient = target > current ? attackCoefficient : releaseCoefficient
            smoothedBins[index] = current + ((target - current) * coefficient)
        }
    }

    private func updateEnergy(deltaTime: Float) -> Float {
        guard !smoothedBins.isEmpty else {
            smoothedEnergy = 0
            return 0
        }

        var weightedMean: Float = 0
        var weightedSquare: Float = 0
        let count = Float(smoothedBins.count)

        for (index, value) in smoothedBins.enumerated() {
            let t = Float(index) / Float(max(smoothedBins.count - 1, 1))
            let emphasis = 1.08 - (0.42 * t)
            let weighted = value * emphasis
            weightedMean += weighted
            weightedSquare += weighted * weighted
        }

        weightedMean /= count
        weightedSquare /= count

        let rms = sqrt(weightedSquare)
        let target = max(0, min(((weightedMean * 0.35) + (rms * 0.65)) * 1.24, 1))

        let attackCoefficient = smoothingCoefficient(timeConstant: energyAttackTime, deltaTime: deltaTime)
        let releaseCoefficient = smoothingCoefficient(timeConstant: energyReleaseTime, deltaTime: deltaTime)
        let coefficient = target > smoothedEnergy ? attackCoefficient : releaseCoefficient
        smoothedEnergy += (target - smoothedEnergy) * coefficient

        return max(0, min(smoothedEnergy, 1))
    }

    private func smoothingCoefficient(timeConstant: Float, deltaTime: Float) -> Float {
        let resolvedTime = max(0.001, timeConstant)
        let resolvedDelta = max(1 / 240, min(deltaTime, 0.25))
        return 1 - exp(-resolvedDelta / resolvedTime)
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
