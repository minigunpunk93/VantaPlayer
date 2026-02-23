import AppKit
import Combine
import Foundation

@MainActor
final class WindowModeController: NSObject, ObservableObject {
    private let normalMinSize = NSSize(width: 520, height: 420)
    private let fullscreenMinSize = NSSize(width: 240, height: 160)
    private let unconstrainedSize = NSSize(
        width: CGFloat.greatestFiniteMagnitude,
        height: CGFloat.greatestFiniteMagnitude
    )

    @Published private(set) var chromeInsets = ChromeInsets.fallback

    private weak var window: NSWindow?
    private weak var proxiedDelegate: NSWindowDelegate?

    private var isCompactModeEnabled = false
    private var compactTargetSize = NSSize(width: 390, height: 520)

    func attach(window: NSWindow) {
        guard self.window !== window else { return }

        if let existingWindow = self.window,
           existingWindow.delegate === self {
            existingWindow.delegate = proxiedDelegate
        }

        self.window = window
        proxiedDelegate = (window.delegate === self) ? nil : window.delegate
        window.delegate = self
        refreshChromeInsets(for: window)

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
        refreshChromeInsets(for: window)

        if window.styleMask.contains(.fullScreen) {
            relaxResizeLimitsForFullscreen(on: window)
            return
        }

        if isCompactModeEnabled {
            applyCompactMode(on: window, setContentSize: setContentSize)
        } else {
            applyNormalMode(on: window)
        }
    }

    private func applyCompactMode(on window: NSWindow, setContentSize: Bool) {
        compactTargetSize = computeCompactSize(for: window)

        if setContentSize {
            let currentSize = window.contentView?.frame.size ?? .zero
            if !approximatelyEqual(currentSize, compactTargetSize) {
                window.setContentSize(compactTargetSize)
            }
        }

        if !approximatelyEqual(window.minSize, compactTargetSize) {
            window.minSize = compactTargetSize
        }

        if !approximatelyEqual(window.maxSize, compactTargetSize) {
            window.maxSize = compactTargetSize
        }
    }

    private func applyNormalMode(on window: NSWindow) {
        if !approximatelyEqual(window.minSize, normalMinSize) {
            window.minSize = normalMinSize
        }

        if !approximatelyEqual(window.maxSize, unconstrainedSize) {
            window.maxSize = unconstrainedSize
        }
    }

    private func relaxResizeLimitsForFullscreen(on window: NSWindow) {
        window.minSize = fullscreenMinSize
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

        let ratio: CGFloat = 0.8
        let targetArea = (visibleFrame.width * visibleFrame.height) / 6

        var targetWidth = sqrt(targetArea * ratio)
        var targetHeight = sqrt(targetArea / ratio)

        let preferredMinWidth: CGFloat = 390
        let preferredMinHeight: CGFloat = 520
        let preferredMaxWidth: CGFloat = 540
        let preferredMaxHeight: CGFloat = 760

        let maxWidth = max(320, min(preferredMaxWidth, visibleFrame.width - 80))
        let maxHeight = max(360, min(preferredMaxHeight, visibleFrame.height - 80))
        let minWidth = min(preferredMinWidth, maxWidth)
        let minHeight = min(preferredMinHeight, maxHeight)

        targetWidth = min(max(targetWidth, minWidth), maxWidth)
        targetHeight = min(max(targetHeight, minHeight), maxHeight)

        return NSSize(width: floor(targetWidth), height: floor(targetHeight))
    }

    private func approximatelyEqual(_ lhs: NSSize, _ rhs: NSSize) -> Bool {
        abs(lhs.width - rhs.width) < 0.5 && abs(lhs.height - rhs.height) < 0.5
    }

    private func refreshChromeInsets(for window: NSWindow) {
        let nextInsets = WindowChromeConfigurator.shared.configureIfNeeded(window)
        if chromeInsets != nextInsets {
            chromeInsets = nextInsets
        }
    }
}

extension WindowModeController: NSWindowDelegate {
    nonisolated func windowWillEnterFullScreen(_ notification: Notification) {
        MainActor.assumeIsolated { [weak self] in
            guard let self, let window = self.window else { return }
            self.relaxResizeLimitsForFullscreen(on: window)
            self.proxiedDelegate?.windowWillEnterFullScreen?(notification)
        }
    }

    nonisolated func windowDidEnterFullScreen(_ notification: Notification) {
        MainActor.assumeIsolated { [weak self] in
            guard let self, let window = self.window else { return }
            self.refreshChromeInsets(for: window)
            self.proxiedDelegate?.windowDidEnterFullScreen?(notification)
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

    nonisolated func windowDidResize(_ notification: Notification) {
        MainActor.assumeIsolated { [weak self] in
            guard let self, let window = self.window else { return }
            self.refreshChromeInsets(for: window)
            self.proxiedDelegate?.windowDidResize?(notification)
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
