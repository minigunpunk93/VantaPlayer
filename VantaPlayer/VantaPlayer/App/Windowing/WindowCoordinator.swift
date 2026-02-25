import AppKit
import Combine
import Foundation

@MainActor
final class WindowCoordinator: NSObject, ObservableObject {
    private let fullNormalContentSize = NSSize(width: 520, height: 640)
    private let normalNoPlaylistContentHeight: CGFloat = 430
    private let normalNoInspectorContentHeight: CGFloat = 430
    private let normalMinContentSize = NSSize(width: 420, height: 180)
    private let compactContentHeight: CGFloat = 88
    private let compactMinContentWidth: CGFloat = 420
    private let compactMaxScreenWidthFraction: CGFloat = 0.5
    private var compactDefaultContentWidth: CGFloat { fullNormalContentSize.width }

    private let fullscreenMinSize = NSSize(width: 240, height: 160)
    private let transitionMinSize = NSSize(width: 1, height: 1)
    private let unconstrainedSize = NSSize(
        width: CGFloat.greatestFiniteMagnitude,
        height: CGFloat.greatestFiniteMagnitude
    )
    private let frameApplyThreshold: CGFloat = 1.0

    @Published private(set) var chromeInsets = ChromeInsets.fallback

    private weak var window: NSWindow?
    private weak var proxiedDelegate: NSWindowDelegate?

    private enum NormalHeightPreset: Equatable {
        case full
        case noPlaylist
        case noInspector
    }

    private struct CompactWidthLimits {
        let min: CGFloat
        let max: CGFloat
    }

    private var isCompactModeEnabled = WindowCoordinator.storedBool(AppStorageKeys.isCompactMode, default: false)
    private var isPlaylistVisible = true
    private var isInspectorVisible = WindowCoordinator.storedBool(AppStorageKeys.isInspectorVisible, default: true)
    private var normalHeightPreset: NormalHeightPreset = .full
    private var isApplyingWindowMode = false

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
        normalHeightPreset = resolvedNormalHeightPreset(
            playlistVisible: isPlaylistVisible,
            inspectorVisible: isInspectorVisible
        )
        applyCurrentWindowMode(setContentSize: true, animateResize: false)
    }

    func setCompactModeEnabled(_ enabled: Bool) {
        guard isCompactModeEnabled != enabled else { return }
        isCompactModeEnabled = enabled
        applyCurrentWindowMode(setContentSize: true, animateResize: false)
    }

    func setSectionVisibility(playlistVisible: Bool, inspectorVisible: Bool) {
        // Playlist is always visible in normal mode.
        let resolvedPlaylistVisible = true
        let didChange = isPlaylistVisible != resolvedPlaylistVisible || isInspectorVisible != inspectorVisible

        _ = playlistVisible
        isPlaylistVisible = resolvedPlaylistVisible
        isInspectorVisible = inspectorVisible

        guard didChange else { return }
        guard !isCompactModeEnabled else { return }
        guard let window, !window.styleMask.contains(.fullScreen) else { return }

        normalHeightPreset = resolvedNormalHeightPreset(
            playlistVisible: resolvedPlaylistVisible,
            inspectorVisible: inspectorVisible
        )
        applyCurrentWindowMode(setContentSize: true, animateResize: false)
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
        let compactBaseFrameSize = compactTargetFrameSize(for: window)
        let widthLimits = compactFrameWidthLimits(for: window)
        let targetWidth = compactTargetFrameWidth(for: window, widthLimits: widthLimits)
        let targetFrameSize = NSSize(width: targetWidth, height: compactBaseFrameSize.height)

        relaxResizeLimitsForTransition(on: window)

        if setContentSize {
            resizeWindowTopAnchored(
                window,
                targetFrameSize: targetFrameSize,
                animate: animateResize && shouldAnimateWindowResize
            )
        }

        lockCompactSize(
            on: window,
            minWidth: widthLimits.min,
            maxWidth: widthLimits.max,
            fixedHeight: compactBaseFrameSize.height
        )
    }

    private func applyNormalMode(on window: NSWindow, setContentSize: Bool, animateResize: Bool) {
        let targetFrameSize = normalTargetFrameSize(for: window)
        let minimumFrameHeight = resolvedNormalMinimumFrameHeight(
            for: window,
            targetFrameSize: targetFrameSize
        )

        if setContentSize {
            resizeWindowTopAnchored(
                window,
                targetFrameSize: targetFrameSize,
                animate: animateResize && shouldAnimateWindowResize
            )
        }

        lockNormalResizeLimits(
            on: window,
            fixedFrameWidth: targetFrameSize.width,
            minimumFrameHeight: minimumFrameHeight
        )
    }

    private func relaxResizeLimitsForTransition(on window: NSWindow) {
        if !approximatelyEqual(window.minSize, transitionMinSize) {
            window.minSize = transitionMinSize
        }

        if !approximatelyEqual(window.maxSize, unconstrainedSize) {
            window.maxSize = unconstrainedSize
        }
    }

    private func lockNormalResizeLimits(on window: NSWindow, fixedFrameWidth: CGFloat, minimumFrameHeight: CGFloat) {
        let normalMinSize = NSSize(width: fixedFrameWidth, height: minimumFrameHeight)
        let normalMaxSize = NSSize(width: fixedFrameWidth, height: unconstrainedSize.height)

        if !approximatelyEqual(window.minSize, normalMinSize) {
            window.minSize = normalMinSize
        }

        if !approximatelyEqual(window.maxSize, normalMaxSize) {
            window.maxSize = normalMaxSize
        }
    }

    private func lockCompactSize(on window: NSWindow, minWidth: CGFloat, maxWidth: CGFloat, fixedHeight: CGFloat) {
        let compactMinSize = NSSize(width: minWidth, height: fixedHeight)
        let compactMaxSize = NSSize(width: maxWidth, height: fixedHeight)

        if !approximatelyEqual(window.minSize, compactMinSize) {
            window.minSize = compactMinSize
        }

        if !approximatelyEqual(window.maxSize, compactMaxSize) {
            window.maxSize = compactMaxSize
        }
    }

    private func relaxResizeLimitsForFullscreen(on window: NSWindow) {
        window.minSize = fullscreenMinSize
        window.maxSize = unconstrainedSize
    }

    private func normalTargetFrameSize(for window: NSWindow) -> NSSize {
        targetFrameSize(for: window, contentSize: normalContentSize(for: normalHeightPreset))
    }

    private func normalMinimumFrameSize(for window: NSWindow) -> NSSize {
        targetFrameSize(for: window, contentSize: normalMinContentSize)
    }

    private func resolvedNormalMinimumFrameHeight(for window: NSWindow, targetFrameSize: NSSize? = nil) -> CGFloat {
        if isInspectorVisible {
            return (targetFrameSize ?? normalTargetFrameSize(for: window)).height
        }
        return normalMinimumFrameSize(for: window).height
    }

    private func compactTargetFrameSize(for window: NSWindow) -> NSSize {
        targetFrameSize(
            for: window,
            contentSize: NSSize(width: compactDefaultContentWidth, height: compactContentHeight)
        )
    }

    private func compactTargetFrameWidth(for window: NSWindow, widthLimits: CompactWidthLimits) -> CGFloat {
        let currentWidth = window.frame.width
        let fallbackWidth = compactTargetFrameSize(for: window).width
        let preferredWidth = (currentWidth.isFinite && currentWidth > 0) ? currentWidth : fallbackWidth
        return preferredWidth.clamped(to: widthLimits.min...widthLimits.max)
    }

    private func compactFrameWidthLimits(for window: NSWindow) -> CompactWidthLimits {
        let minimumFrameWidth = compactFrameWidth(for: window, contentWidth: compactMinContentWidth)
        let defaultFrameWidth = compactTargetFrameSize(for: window).width

        let halfScreenFrameWidth = compactHalfScreenFrameWidth(for: window)
        let resolvedMaxWidth = max(halfScreenFrameWidth, 1)
        let resolvedMinWidth = min(max(minimumFrameWidth, 1), resolvedMaxWidth)

        if resolvedMaxWidth.isFinite, resolvedMaxWidth > 0 {
            return CompactWidthLimits(min: resolvedMinWidth, max: resolvedMaxWidth)
        }

        let fallbackWidth = max(defaultFrameWidth, 1)
        return CompactWidthLimits(min: fallbackWidth, max: fallbackWidth)
    }

    private func compactHalfScreenFrameWidth(for window: NSWindow) -> CGFloat {
        guard let screen = window.screen ?? NSScreen.main else {
            return compactTargetFrameSize(for: window).width
        }

        let halfWidth = floor(screen.visibleFrame.width * compactMaxScreenWidthFraction)
        guard halfWidth.isFinite, halfWidth > 0 else {
            return compactTargetFrameSize(for: window).width
        }
        return halfWidth
    }

    private func compactFrameWidth(for window: NSWindow, contentWidth: CGFloat) -> CGFloat {
        targetFrameSize(
            for: window,
            contentSize: NSSize(width: contentWidth, height: compactContentHeight)
        ).width
    }

    private func normalContentSize(for preset: NormalHeightPreset) -> NSSize {
        switch preset {
        case .full:
            return fullNormalContentSize
        case .noPlaylist:
            return NSSize(width: fullNormalContentSize.width, height: normalNoPlaylistContentHeight)
        case .noInspector:
            return NSSize(width: fullNormalContentSize.width, height: normalNoInspectorContentHeight)
        }
    }

    private func resolvedNormalHeightPreset(playlistVisible: Bool, inspectorVisible: Bool) -> NormalHeightPreset {
        if !playlistVisible {
            return .noPlaylist
        }
        if !inspectorVisible {
            return .noInspector
        }
        return .full
    }

    private func targetFrameSize(for window: NSWindow, contentSize: NSSize) -> NSSize {
        let targetContentRect = NSRect(origin: .zero, size: contentSize)
        let targetFrameRect = window.frameRect(forContentRect: targetContentRect)

        if targetFrameRect.width.isFinite,
           targetFrameRect.width > 0,
           targetFrameRect.height.isFinite,
           targetFrameRect.height > 0 {
            return NSSize(width: floor(targetFrameRect.width), height: floor(targetFrameRect.height))
        }

        let currentFrame = window.frame
        let currentContentRect = window.contentRect(forFrameRect: currentFrame)
        let chromeWidth = max(0, currentFrame.width - currentContentRect.width)
        let chromeHeight = max(0, currentFrame.height - currentContentRect.height)

        return NSSize(
            width: floor(contentSize.width + chromeWidth),
            height: floor(contentSize.height + chromeHeight)
        )
    }

    private func resizeWindowTopAnchored(_ window: NSWindow, targetFrameSize: NSSize, animate: Bool) {
        let oldFrame = window.frame
        let newFrame = NSRect(
            x: oldFrame.minX,
            y: oldFrame.maxY - targetFrameSize.height,
            width: targetFrameSize.width,
            height: targetFrameSize.height
        )

        guard frameDiffersMeaningfully(oldFrame, newFrame) else { return }
        window.setFrame(newFrame, display: true, animate: animate)
    }

    private func frameDiffersMeaningfully(_ lhs: NSRect, _ rhs: NSRect) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) >= frameApplyThreshold ||
        abs(lhs.origin.y - rhs.origin.y) >= frameApplyThreshold ||
        abs(lhs.size.width - rhs.size.width) >= frameApplyThreshold ||
        abs(lhs.size.height - rhs.size.height) >= frameApplyThreshold
    }

    private var shouldAnimateWindowResize: Bool {
        !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private static func storedBool(_ key: String, default defaultValue: Bool) -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: key) != nil else {
            return defaultValue
        }
        return defaults.bool(forKey: key)
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

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

extension WindowCoordinator: NSWindowDelegate {
    nonisolated func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        MainActor.assumeIsolated { [weak self] in
            guard let self else { return frameSize }

            guard !sender.styleMask.contains(.fullScreen) else {
                return self.proxiedDelegate?.windowWillResize?(sender, to: frameSize) ?? frameSize
            }

            if self.isCompactModeEnabled {
                let widthLimits = self.compactFrameWidthLimits(for: sender)
                let clampedWidth = frameSize.width.clamped(to: widthLimits.min...widthLimits.max)
                let fixedHeight = self.compactTargetFrameSize(for: sender).height
                return NSSize(width: clampedWidth, height: fixedHeight)
            }

            // Keep classic mode at a fixed width; only height remains resizable.
            let targetFrameSize = self.normalTargetFrameSize(for: sender)
            let fixedWidth = targetFrameSize.width
            let minimumHeight = self.resolvedNormalMinimumFrameHeight(
                for: sender,
                targetFrameSize: targetFrameSize
            )
            let clampedHeight = max(frameSize.height, minimumHeight)
            return NSSize(width: fixedWidth, height: clampedHeight)
        }
    }

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
            guard let self else { return }
            if self.isCompactModeEnabled {
                self.applyCurrentWindowMode(setContentSize: false, animateResize: false)
            }
            self.proxiedDelegate?.windowDidEndLiveResize?(notification)
        }
    }

    nonisolated func windowDidChangeScreen(_ notification: Notification) {
        MainActor.assumeIsolated { [weak self] in
            guard let self, let window = self.window else { return }
            if !window.styleMask.contains(.fullScreen) {
                self.applyCurrentWindowMode(setContentSize: self.isCompactModeEnabled, animateResize: false)
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
