import AppKit
import SwiftUI

struct ChromeInsets: Equatable {
    var top: CGFloat
    var leading: CGFloat

    static let fallback = ChromeInsets(top: 12, leading: 14)
    static let fullScreen = ChromeInsets(top: 8, leading: 12)
}

private struct ChromeInsetsKey: EnvironmentKey {
    static let defaultValue = ChromeInsets.fallback
}

extension EnvironmentValues {
    var chromeInsets: ChromeInsets {
        get { self[ChromeInsetsKey.self] }
        set { self[ChromeInsetsKey.self] = newValue }
    }
}

@MainActor
final class WindowChromeConfigurator {
    static let shared = WindowChromeConfigurator()

    private let configuredWindows = NSHashTable<NSWindow>.weakObjects()

    func configureIfNeeded(_ window: NSWindow) -> ChromeInsets {
        if !configuredWindows.allObjects.contains(where: { $0 === window }) {
            configure(window)
            configuredWindows.add(window)
        }

        return computeInsets(for: window)
    }

    private func configure(_ window: NSWindow) {
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = true
        if let closeButton = window.standardWindowButton(.closeButton) {
            closeButton.isHidden = false
            closeButton.target = NSApp
            closeButton.action = #selector(NSApplication.terminate(_:))
            closeButton.toolTip = "Quit VantaPlayer"
        }
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        if #available(macOS 11.0, *) {
            window.toolbarStyle = .unifiedCompact
            window.titlebarSeparatorStyle = .none
        }
    }

    private func computeInsets(for window: NSWindow) -> ChromeInsets {
        if window.styleMask.contains(.fullScreen) {
            return .fullScreen
        }

        var insets = ChromeInsets.fallback
        guard let contentView = window.contentView else {
            return insets
        }

        let buttonTypes: [NSWindow.ButtonType] = [.miniaturizeButton, .zoomButton]
        let buttonFrames = buttonTypes.compactMap { type -> CGRect? in
            guard let button = window.standardWindowButton(type),
                  !button.isHidden else {
                return nil
            }

            let frameInWindow = button.convert(button.bounds, to: nil)
            return contentView.convert(frameInWindow, from: nil)
        }

        guard !buttonFrames.isEmpty else {
            return insets
        }

        if let maxX = buttonFrames.map(\.maxX).max() {
            insets.leading = max(insets.leading, maxX + 12)
        }

        if contentView.isFlipped {
            if let maxY = buttonFrames.map(\.maxY).max() {
                insets.top = max(insets.top, maxY + 6)
            }
        } else if let minY = buttonFrames.map(\.minY).min() {
            insets.top = max(insets.top, (contentView.bounds.maxY - minY) + 6)
        }

        return insets
    }
}

private struct WindowChromeInstaller: ViewModifier {
    @AppStorage(AppStorageKeys.isCompactMode) private var isCompactMode = false
    @StateObject private var windowCoordinator = WindowCoordinator()

    func body(content: Content) -> some View {
        content
            .environment(\.chromeInsets, windowCoordinator.chromeInsets)
            .background {
                WindowAccessor { window in
                    windowCoordinator.attach(window: window)
                    windowCoordinator.setCompactModeEnabled(isCompactMode)
                }
                .frame(width: 0, height: 0)
            }
            .onChange(of: isCompactMode) { _, newValue in
                windowCoordinator.setCompactModeEnabled(newValue)
            }
    }
}

extension View {
    func installWindowChrome() -> some View {
        modifier(WindowChromeInstaller())
    }
}
