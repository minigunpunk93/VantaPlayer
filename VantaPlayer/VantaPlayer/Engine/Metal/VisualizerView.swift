import Foundation
import MetalKit
import SwiftUI

struct VisualizerView: NSViewRepresentable {
    struct PlaybackSnapshot: Sendable {
        var isPlaying: Bool
        var playbackTime: TimeInterval
        var energy: Float
        var reduceMotion: Bool
    }

    var snapshot: PlaybackSnapshot

    func makeCoordinator() -> Coordinator {
        Coordinator(snapshot: snapshot)
    }

    func makeNSView(context: Context) -> MTKView {
        let metalView = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        metalView.clearColor = MTLClearColor(red: 0.02, green: 0.03, blue: 0.06, alpha: 1)
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.enableSetNeedsDisplay = false
        metalView.isPaused = false
        metalView.framebufferOnly = true
        metalView.preferredFramesPerSecond = snapshot.reduceMotion ? 30 : 60
        metalView.sampleCount = 1
        return metalView
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.snapshot = snapshot
        nsView.preferredFramesPerSecond = snapshot.reduceMotion ? 30 : 60
        context.coordinator.installRendererIfNeeded(on: nsView)
    }

    final class Coordinator {
        var snapshot: PlaybackSnapshot
        private var renderer: VisualizerRenderer?
        private var didScheduleRendererSetup = false

        init(snapshot: PlaybackSnapshot) {
            self.snapshot = snapshot
        }

        func installRendererIfNeeded(on view: MTKView) {
            guard renderer == nil, !didScheduleRendererSetup else { return }
            didScheduleRendererSetup = true

            Task { @MainActor [weak self, weak view] in
                await Task.yield()
                guard let self, let view, self.renderer == nil, let device = view.device else {
                    return
                }

                self.renderer = VisualizerRenderer(device: device) { [weak self] in
                    guard let self else {
                        return VisualizerRenderer.PlaybackState(
                            isPlaying: false,
                            playbackTime: 0,
                            energy: 0.12,
                            reduceMotion: false
                        )
                    }

                    return VisualizerRenderer.PlaybackState(
                        isPlaying: self.snapshot.isPlaying,
                        playbackTime: self.snapshot.playbackTime,
                        energy: self.snapshot.energy,
                        reduceMotion: self.snapshot.reduceMotion
                    )
                }

                view.delegate = self.renderer
            }
        }
    }
}
