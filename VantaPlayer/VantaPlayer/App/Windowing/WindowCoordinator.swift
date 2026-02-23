import AppKit
import Combine
import Foundation

@MainActor
final class WindowCoordinator: NSObject, ObservableObject {
    private let normalMinSize = NSSize(width: 520, height: 420)
    private let fullscreenMinSize = NSSize(width: 240, height: 160)
    private let unconstrainedSize = NSSize(
        width: CGFloat.greatestFiniteMagnitude,
        height: CGFloat.greatestFiniteMagnitude
    )
    private let compactContentHeight: CGFloat = 140
    private let fallbackCompactContentWidth: CGFloat = 420
    private let compactFrameHeightValidationThreshold: CGFloat = 64
    private let frameApplyThreshold: CGFloat = 1.0

    @Published private(set) var chromeInsets = ChromeInsets.fallback

    private weak var window: NSWindow?
    private weak var proxiedDelegate: NSWindowDelegate?

    private var isCompactModeEnabled = false
    private var lastNormalFrame: NSRect?
    private var isApplyingWindowMode = false
    private var pendingPostToggleReconcile: DispatchWorkItem?

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
            self?.applyCurrentWindowMode(setContentSize: true, animateResize: false)
        }
    }

    func setCompactModeEnabled(_ enabled: Bool) {
        guard isCompactModeEnabled != enabled else { return }
        isCompactModeEnabled = enabled
        if enabled, let window {
            lastNormalFrame = window.frame
        }
        applyCurrentWindowMode(setContentSize: true, animateResize: shouldAnimateWindowResize)
        schedulePostToggleReconcile()
    }

    private func applyCurrentWindowMode(setContentSize: Bool, animateResize: Bool) {
        guard !isApplyingWindowMode else { return }
        guard let window else { return }
        isApplyingWindowMode = true
        defer { isApplyingWindowMode = false }

        refreshChromeInsets(for: window)

        if window.styleMask.contains(.fullScreen) {
            relaxResizeLimitsForFullscreen(on: window)
            return
        }

        if isCompactModeEnabled {
            applyCompactMode(on: window, setContentSize: setContentSize, animateResize: animateResize)
        } else {
            applyNormalMode(on: window, setContentSize: setContentSize, animateResize: animateResize)
        }
    }

    private func applyCompactMode(on window: NSWindow, setContentSize: Bool, animateResize: Bool) {
        if lastNormalFrame == nil {
            lastNormalFrame = window.frame
        }

        let oldFrame = window.frame
        let targetFrameHeight = min(compactTargetFrameHeight(for: window), oldFrame.height)
        let compactTargetSize = NSSize(width: oldFrame.width, height: targetFrameHeight)

        // Lock first so compact target is not clamped by normal minSize.
        applyCompactLock(on: window, targetSize: compactTargetSize)

        if setContentSize {
            resizeWindowTopAnchored(
                window,
                targetFrameHeight: targetFrameHeight,
                animate: animateResize && shouldAnimateWindowResize
            )
        }
    }

    private func applyNormalMode(on window: NSWindow, setContentSize: Bool, animateResize: Bool) {
        // Unlock first so restore is not clamped by compact lock.
        applyStandardResizeLimits(on: window)

        if setContentSize {
            restoreNormalFrame(
                on: window,
                animate: animateResize && shouldAnimateWindowResize
            )
        }
        lastNormalFrame = nil
    }

    private func applyCompactLock(on window: NSWindow, targetSize: NSSize) {
        if !approximatelyEqual(window.minSize, targetSize) {
            window.minSize = targetSize
        }

        if !approximatelyEqual(window.maxSize, targetSize) {
            window.maxSize = targetSize
        }
    }

    private func applyStandardResizeLimits(on window: NSWindow) {
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

    private func compactTargetFrameHeight(for window: NSWindow) -> CGFloat {
        let currentFrame = window.frame
        let currentContentRect = window.contentRect(forFrameRect: currentFrame)
        let targetContentWidth: CGFloat
        if currentContentRect.width.isFinite, currentContentRect.width > 0 {
            targetContentWidth = currentContentRect.width
        } else {
            targetContentWidth = fallbackCompactContentWidth
        }

        let targetContentRect = NSRect(
            x: 0,
            y: 0,
            width: targetContentWidth,
            height: compactContentHeight
        )
        let targetFrameRect = window.frameRect(forContentRect: targetContentRect)
        let fallbackFrameHeight = compactContentHeight + max(0, currentFrame.height - currentContentRect.height)

        if targetFrameRect.height.isFinite, targetFrameRect.height > 0 {
            let computedHeight = floor(targetFrameRect.height)
            let fallbackHeight = floor(max(fallbackFrameHeight, compactContentHeight))

            // Guard against pathological conversions that occasionally produce oversized frame heights.
            if abs(computedHeight - fallbackHeight) <= compactFrameHeightValidationThreshold {
                return computedHeight
            }

            return fallbackHeight
        }

        return floor(max(fallbackFrameHeight, compactContentHeight))
    }

    private func schedulePostToggleReconcile() {
        pendingPostToggleReconcile?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.applyCurrentWindowMode(setContentSize: true, animateResize: false)
        }

        pendingPostToggleReconcile = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    private func restoreNormalFrame(on window: NSWindow, animate: Bool) {
        guard let lastNormalFrame else { return }

        let currentFrame = window.frame
        let targetFrame = NSRect(
            x: lastNormalFrame.minX,
            y: currentFrame.maxY - lastNormalFrame.height,
            width: lastNormalFrame.width,
            height: lastNormalFrame.height
        )

        guard frameDiffersMeaningfully(currentFrame, targetFrame) else { return }
        window.setFrame(targetFrame, display: true, animate: animate)
    }

    private func resizeWindowTopAnchored(_ window: NSWindow, targetFrameHeight: CGFloat, animate: Bool) {
        let oldFrame = window.frame
        let newFrame = NSRect(
            x: oldFrame.minX,
            y: oldFrame.maxY - targetFrameHeight,
            width: oldFrame.width,
            height: targetFrameHeight
        )

        guard frameDiffersMeaningfully(oldFrame, newFrame) else { return }
        window.setFrame(newFrame, display: true, animate: animate)
    }

    private func frameDiffersMeaningfully(_ lhs: NSRect, _ rhs: NSRect) -> Bool {
        abs(lhs.origin.y - rhs.origin.y) >= frameApplyThreshold ||
        abs(lhs.size.height - rhs.size.height) >= frameApplyThreshold
    }

    private var shouldAnimateWindowResize: Bool {
        !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
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
            self.applyCurrentWindowMode(setContentSize: true, animateResize: false)
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

    nonisolated func windowDidEndLiveResize(_ notification: Notification) {
        MainActor.assumeIsolated { [weak self] in
            guard let self, let window = self.window else { return }
            if !self.isCompactModeEnabled, !window.styleMask.contains(.fullScreen) {
                self.lastNormalFrame = window.frame
            }
            self.proxiedDelegate?.windowDidEndLiveResize?(notification)
        }
    }

    nonisolated func windowDidChangeScreen(_ notification: Notification) {
        MainActor.assumeIsolated { [weak self] in
            guard let self else { return }
            if self.isCompactModeEnabled {
                self.applyCurrentWindowMode(setContentSize: true, animateResize: false)
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
