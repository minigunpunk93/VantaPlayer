import AppKit
import Foundation

@MainActor
final class WindowCoordinator: NSObject {
    private let normalMinSize = NSSize(width: 820, height: 520)
    private let unconstrainedSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

    private weak var window: NSWindow?
    private weak var proxiedDelegate: NSWindowDelegate?

    private var isCompactModeEnabled = false
    private var compactTargetSize = NSSize(width: 820, height: 520)

    func attach(window: NSWindow) {
        guard self.window !== window else { return }

        if let existingWindow = self.window,
           existingWindow.delegate === self {
            existingWindow.delegate = proxiedDelegate
        }

        self.window = window
        proxiedDelegate = (window.delegate === self) ? nil : window.delegate
        window.delegate = self

        DispatchQueue.main.async { [weak self] in
            self?.applyCurrentWindowMode(setContentSize: true)
        }
    }

    func setCompactModeEnabled(_ enabled: Bool) {
        isCompactModeEnabled = enabled
        applyCurrentWindowMode(setContentSize: true)
    }

    private func applyCurrentWindowMode(setContentSize: Bool) {
        guard let window else { return }

        if window.styleMask.contains(.fullScreen) {
            relaxResizeLimitsForFullscreen(on: window)
            return
        }

        if isCompactModeEnabled {
            compactTargetSize = computeCompactSize(for: window)
            if setContentSize {
                window.setContentSize(compactTargetSize)
            }
            applyCompactLock(on: window)
        } else {
            applyStandardResizeLimits(on: window)
        }
    }

    private func applyCompactLock(on window: NSWindow) {
        window.minSize = compactTargetSize
        window.maxSize = compactTargetSize
    }

    private func applyStandardResizeLimits(on window: NSWindow) {
        window.minSize = normalMinSize
        window.maxSize = unconstrainedSize
    }

    private func relaxResizeLimitsForFullscreen(on window: NSWindow) {
        window.minSize = NSSize(width: 240, height: 160)
        window.maxSize = unconstrainedSize
    }

    private func computeCompactSize(for window: NSWindow) -> NSSize {
        let visibleFrame: CGRect
        if let screenFrame = window.screen?.visibleFrame {
            visibleFrame = screenFrame
        } else if let mainFrame = NSScreen.main?.visibleFrame {
            visibleFrame = mainFrame
        } else {
            visibleFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        }

        let ratio: CGFloat = 16.0 / 10.0
        let targetArea = (visibleFrame.width * visibleFrame.height) / 6
        var targetWidth = sqrt(targetArea * ratio)
        var targetHeight = sqrt(targetArea / ratio)

        let minWidth: CGFloat = 560
        let minHeight: CGFloat = 320
        let maxWidth: CGFloat = min(visibleFrame.width * 0.84, 1100)
        let maxHeight: CGFloat = min(visibleFrame.height * 0.84, 740)

        targetWidth = min(max(targetWidth, minWidth), maxWidth)
        targetHeight = min(max(targetHeight, minHeight), maxHeight)

        return NSSize(width: floor(targetWidth), height: floor(targetHeight))
    }
}

extension WindowCoordinator: NSWindowDelegate {
    nonisolated func windowWillEnterFullScreen(_ notification: Notification) {
        MainActor.assumeIsolated { [weak self] in
            guard let self, let window = self.window else { return }
            self.relaxResizeLimitsForFullscreen(on: window)
            self.proxiedDelegate?.windowWillEnterFullScreen?(notification)
        }
    }

    nonisolated func windowDidEnterFullScreen(_ notification: Notification) {
        MainActor.assumeIsolated { [weak self] in
            self?.proxiedDelegate?.windowDidEnterFullScreen?(notification)
        }
    }

    nonisolated func windowWillExitFullScreen(_ notification: Notification) {
        MainActor.assumeIsolated { [weak self] in
            guard let self, let window = self.window else { return }
            self.relaxResizeLimitsForFullscreen(on: window)
            self.proxiedDelegate?.windowWillExitFullScreen?(notification)
        }
    }

    nonisolated func windowDidExitFullScreen(_ notification: Notification) {
        MainActor.assumeIsolated { [weak self] in
            guard let self else { return }
            self.applyCurrentWindowMode(setContentSize: true)
            self.proxiedDelegate?.windowDidExitFullScreen?(notification)
        }
    }

    nonisolated func windowDidChangeScreen(_ notification: Notification) {
        MainActor.assumeIsolated { [weak self] in
            guard let self else { return }
            if self.isCompactModeEnabled {
                self.applyCurrentWindowMode(setContentSize: true)
            }
            self.proxiedDelegate?.windowDidChangeScreen?(notification)
        }
    }

    nonisolated func windowShouldClose(_ sender: NSWindow) -> Bool {
        MainActor.assumeIsolated { [weak self] in
            self?.proxiedDelegate?.windowShouldClose?(sender) ?? true
        }
    }
}
