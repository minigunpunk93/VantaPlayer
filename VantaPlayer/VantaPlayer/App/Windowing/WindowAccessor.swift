import AppKit
import SwiftUI

struct WindowAccessor: NSViewRepresentable {
    let onResolveWindow: (NSWindow) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onResolveWindow: onResolveWindow)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onResolveWindow = onResolveWindow
        context.coordinator.attach(to: nsView)
    }

    final class Coordinator {
        var onResolveWindow: (NSWindow) -> Void
        private weak var resolvedWindow: NSWindow?

        init(onResolveWindow: @escaping (NSWindow) -> Void) {
            self.onResolveWindow = onResolveWindow
        }

        func attach(to view: NSView) {
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self,
                      let window = view?.window,
                      self.resolvedWindow !== window else {
                    return
                }

                self.resolvedWindow = window
                self.onResolveWindow(window)
            }
        }
    }
}
