import AppKit
import Combine
import Foundation

@MainActor
final class WindowCoordinator: NSObject, ObservableObject {
    private let fullNormalContentSize = NSSize(width: 520, height: 640)
    private let normalNoPlaylistContentHeight: CGFloat = 430
    private let normalNoInspectorContentHeight: CGFloat = 430
    private let compactContentHeight: CGFloat = 140
    private var compactContentWidth: CGFloat { fullNormalContentSize.width }

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
        let targetFrameSize = compactTargetFrameSize(for: window)
        applyFixedMode(
            on: window,
            targetFrameSize: targetFrameSize,
            setContentSize: setContentSize,
            animateResize: animateResize
        )
    }

    private func applyNormalMode(on window: NSWindow, setContentSize: Bool, animateResize: Bool) {
        let targetFrameSize = normalTargetFrameSize(for: window)
        applyFixedMode(
            on: window,
            targetFrameSize: targetFrameSize,
            setContentSize: setContentSize,
            animateResize: animateResize
        )
    }

    private func applyFixedMode(
        on window: NSWindow,
        targetFrameSize: NSSize,
        setContentSize: Bool,
        animateResize: Bool
    ) {
        relaxResizeLimitsForTransition(on: window)

        if setContentSize {
            resizeWindowTopAnchored(
                window,
                targetFrameSize: targetFrameSize,
                animate: animateResize && shouldAnimateWindowResize
            )
        }

        lockWindowSize(on: window, frameSize: targetFrameSize)
    }

    private func relaxResizeLimitsForTransition(on window: NSWindow) {
        if !approximatelyEqual(window.minSize, transitionMinSize) {
            window.minSize = transitionMinSize
        }

        if !approximatelyEqual(window.maxSize, unconstrainedSize) {
            window.maxSize = unconstrainedSize
        }
    }

    private func lockWindowSize(on window: NSWindow, frameSize: NSSize) {
        if !approximatelyEqual(window.minSize, frameSize) {
            window.minSize = frameSize
        }

        if !approximatelyEqual(window.maxSize, frameSize) {
            window.maxSize = frameSize
        }
    }

    private func relaxResizeLimitsForFullscreen(on window: NSWindow) {
        window.minSize = fullscreenMinSize
        window.maxSize = unconstrainedSize
    }

    private func normalTargetFrameSize(for window: NSWindow) -> NSSize {
        targetFrameSize(for: window, contentSize: normalContentSize(for: normalHeightPreset))
    }

    private func compactTargetFrameSize(for window: NSWindow) -> NSSize {
        targetFrameSize(
            for: window,
            contentSize: NSSize(width: compactContentWidth, height: compactContentHeight)
        )
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
            guard let self else { return }
            self.proxiedDelegate?.windowDidEndLiveResize?(notification)
        }
    }

    nonisolated func windowDidChangeScreen(_ notification: Notification) {
        MainActor.assumeIsolated { [weak self] in
            guard let self, let window = self.window else { return }
            if !window.styleMask.contains(.fullScreen) {
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
