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
    private let minCompactContentHeight: CGFloat = 120
    private let defaultCompactContentHeight: CGFloat = 140
    private let minCompactContentWidth: CGFloat = 420
    private let frameApplyThreshold: CGFloat = 1.0

    @Published private(set) var chromeInsets = ChromeInsets.fallback

    private weak var window: NSWindow?
    private weak var proxiedDelegate: NSWindowDelegate?

    private var isCompactModeEnabled = false
    private var cachedCompactWindowHeight: CGFloat?
    private var lastNormalFrame: NSRect?
    private var hasAppliedCompactFrame = false
    private var lastCompactSizingHadInvalidDimensions = false
    private var isApplyingWindowMode = false
    private var pendingCompactApplyWorkItem: DispatchWorkItem?
    private var pendingCompactRetryWorkItem: DispatchWorkItem?

    func attach(window: NSWindow) {
        guard self.window !== window else { return }

        if let existingWindow = self.window,
           existingWindow.delegate === self {
            existingWindow.delegate = proxiedDelegate
        }

        cancelPendingCompactWorkItems()
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
        cancelPendingCompactWorkItems()
        isCompactModeEnabled = enabled
        cachedCompactWindowHeight = nil

        if enabled {
            scheduleCompactApply()
        } else {
            applyCurrentWindowMode(setContentSize: true, animateResize: true)
        }
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
        let targetHeight = resolvedCompactWindowHeight(for: window)

        if setContentSize {
            if !hasAppliedCompactFrame {
                lastNormalFrame = window.frame
            }

            resizeWindowTopAnchored(
                window,
                targetHeight: targetHeight,
                animate: animateResize && shouldAnimateWindowResize
            )
            hasAppliedCompactFrame = true
        }

        let compactMinSize = NSSize(width: normalMinSize.width, height: targetHeight)
        let compactMaxSize = NSSize(width: unconstrainedSize.width, height: targetHeight)

        if !approximatelyEqual(window.minSize, compactMinSize) {
            window.minSize = compactMinSize
        }

        if !approximatelyEqual(window.maxSize, compactMaxSize) {
            window.maxSize = compactMaxSize
        }
    }

    private func applyNormalMode(on window: NSWindow, setContentSize: Bool, animateResize: Bool) {
        if setContentSize, hasAppliedCompactFrame {
            restoreNormalFrame(on: window, animate: animateResize && shouldAnimateWindowResize)
        }

        if !approximatelyEqual(window.minSize, normalMinSize) {
            window.minSize = normalMinSize
        }

        if !approximatelyEqual(window.maxSize, unconstrainedSize) {
            window.maxSize = unconstrainedSize
        }

        hasAppliedCompactFrame = false
        lastNormalFrame = nil
        lastCompactSizingHadInvalidDimensions = false
    }

    private func relaxResizeLimitsForFullscreen(on window: NSWindow) {
        window.minSize = fullscreenMinSize
        window.maxSize = unconstrainedSize
    }

    private func resolvedCompactWindowHeight(for window: NSWindow) -> CGFloat {
        if let cachedCompactWindowHeight {
            return cachedCompactWindowHeight
        }

        let target = compactTarget(for: window, contentHeight: defaultCompactContentHeight)

        cachedCompactWindowHeight = target.frameHeight
        lastCompactSizingHadInvalidDimensions = target.hadInvalidDimensions
        return target.frameHeight
    }

    private struct CompactTarget {
        let frameHeight: CGFloat
        let hadInvalidDimensions: Bool
    }

    private func compactTarget(for window: NSWindow, contentHeight: CGFloat) -> CompactTarget {
        let safeContentHeight = max(minCompactContentHeight, contentHeight)
        let (contentWidth, wasWidthInvalid) = compactContentWidth(for: window)

        let minimumContentRect = NSRect(x: 0, y: 0, width: contentWidth, height: minCompactContentHeight)
        let desiredContentRect = NSRect(x: 0, y: 0, width: contentWidth, height: safeContentHeight)

        let minimumFrameRect = window.frameRect(forContentRect: minimumContentRect)
        let desiredFrameRect = window.frameRect(forContentRect: desiredContentRect)

        let minimumFrameHeight: CGFloat
        if minimumFrameRect.height.isFinite, minimumFrameRect.height > 0 {
            minimumFrameHeight = floor(minimumFrameRect.height)
        } else {
            minimumFrameHeight = floor(max(window.frame.height, minCompactContentHeight))
        }

        let desiredFrameHeight: CGFloat
        if desiredFrameRect.height.isFinite, desiredFrameRect.height > 0 {
            desiredFrameHeight = floor(desiredFrameRect.height)
        } else {
            desiredFrameHeight = minimumFrameHeight
        }

        let targetFrameHeight = max(minimumFrameHeight, desiredFrameHeight)
        let hadInvalidDimensions = wasWidthInvalid
            || !(minimumFrameRect.height.isFinite && minimumFrameRect.height > 0)
            || !(desiredFrameRect.height.isFinite && desiredFrameRect.height > 0)

        return CompactTarget(
            frameHeight: targetFrameHeight,
            hadInvalidDimensions: hadInvalidDimensions
        )
    }

    private func compactContentWidth(for window: NSWindow) -> (CGFloat, Bool) {
        let layoutWidth = window.contentLayoutRect.width
        guard layoutWidth.isFinite, layoutWidth > 0 else {
            return (minCompactContentWidth, true)
        }

        return (max(layoutWidth, minCompactContentWidth), false)
    }

    private func scheduleCompactApply() {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.isCompactModeEnabled else { return }
            self.applyCurrentWindowMode(setContentSize: true, animateResize: true)
            self.scheduleCompactRetryIfNeeded()
        }

        pendingCompactApplyWorkItem = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    private func scheduleCompactRetryIfNeeded() {
        guard isCompactModeEnabled, lastCompactSizingHadInvalidDimensions else { return }

        let retryWorkItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.isCompactModeEnabled else { return }
            self.cachedCompactWindowHeight = nil
            self.applyCurrentWindowMode(setContentSize: true, animateResize: false)
        }

        pendingCompactRetryWorkItem = retryWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: retryWorkItem)
    }

    private func cancelPendingCompactWorkItems() {
        pendingCompactApplyWorkItem?.cancel()
        pendingCompactApplyWorkItem = nil
        pendingCompactRetryWorkItem?.cancel()
        pendingCompactRetryWorkItem = nil
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

    private func resizeWindowTopAnchored(_ window: NSWindow, targetHeight: CGFloat, animate: Bool) {
        let oldFrame = window.frame
        let newFrame = NSRect(
            x: oldFrame.minX,
            y: oldFrame.maxY - targetHeight,
            width: oldFrame.width,
            height: targetHeight
        )

        guard frameDiffersMeaningfully(oldFrame, newFrame) else { return }
        window.setFrame(newFrame, display: true, animate: animate)
    }

    private var shouldAnimateWindowResize: Bool {
        !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func approximatelyEqual(_ lhs: NSSize, _ rhs: NSSize) -> Bool {
        abs(lhs.width - rhs.width) < 0.5 && abs(lhs.height - rhs.height) < 0.5
    }

    private func frameDiffersMeaningfully(_ lhs: NSRect, _ rhs: NSRect) -> Bool {
        abs(lhs.origin.y - rhs.origin.y) >= frameApplyThreshold ||
        abs(lhs.size.height - rhs.size.height) >= frameApplyThreshold
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
