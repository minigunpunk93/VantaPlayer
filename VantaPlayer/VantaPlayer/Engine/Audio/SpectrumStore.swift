import Foundation

/// Thread-safe shared spectrum/energy state for audio analyzer and Metal renderer.
final class SpectrumStore: @unchecked Sendable {
    struct Snapshot {
        var count: Int
        var energy: Float
    }

    let binCount: Int

    private let lock = NSLock()
    private var bins: [Float]
    private var energy: Float = 0

    init(binCount: Int) {
        self.binCount = max(16, binCount)
        self.bins = [Float](repeating: 0, count: self.binCount)
    }

    func reset() {
        lock.lock()
        bins.withUnsafeMutableBufferPointer { pointer in
            pointer.baseAddress?.update(repeating: 0, count: pointer.count)
        }
        energy = 0
        lock.unlock()
    }

    func write(spectrum source: [Float], energy: Float) {
        lock.lock()
        bins.withUnsafeMutableBufferPointer { destination in
            let count = min(destination.count, source.count)
            if count > 0,
               let destinationBase = destination.baseAddress {
                source.withUnsafeBufferPointer { sourcePointer in
                    guard let sourceBase = sourcePointer.baseAddress else { return }
                    destinationBase.update(from: sourceBase, count: count)
                }
            }
            if count < destination.count,
               let destinationBase = destination.baseAddress {
                destinationBase.advanced(by: count).update(repeating: 0, count: destination.count - count)
            }
        }
        self.energy = max(0, min(energy, 1))
        lock.unlock()
    }

    /// Copies the latest spectrum into a caller-owned preallocated buffer.
    @discardableResult
    func copySpectrum(into destination: UnsafeMutablePointer<Float>, capacity: Int) -> Snapshot {
        let resolvedCapacity = max(0, capacity)

        lock.lock()
        let copyCount = min(resolvedCapacity, bins.count)
        if copyCount > 0 {
            bins.withUnsafeBufferPointer { source in
                guard let sourceBase = source.baseAddress else { return }
                destination.update(from: sourceBase, count: copyCount)
            }
        }
        if copyCount < resolvedCapacity {
            destination.advanced(by: copyCount).update(repeating: 0, count: resolvedCapacity - copyCount)
        }
        let snapshot = Snapshot(count: copyCount, energy: energy)
        lock.unlock()

        return snapshot
    }

    func latestEnergy() -> Float {
        lock.lock()
        let value = energy
        lock.unlock()
        return value
    }
}
