import Foundation
import MetalKit
import SwiftUI

struct VisualizerView: NSViewRepresentable {
    struct PlaybackSnapshot: Sendable {
        var isPlaying: Bool
        var playbackTime: TimeInterval
        var reduceMotion: Bool
        var spectrumStore: SpectrumStore?
    }

    var snapshot: PlaybackSnapshot

    func makeCoordinator() -> Coordinator {
        Coordinator(snapshot: snapshot)
    }

    func makeNSView(context: Context) -> MTKView {
        let metalView = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        metalView.clearColor = MTLClearColor(red: 0.016, green: 0.02, blue: 0.032, alpha: 1)
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.enableSetNeedsDisplay = false
        metalView.isPaused = false
        metalView.framebufferOnly = true
        metalView.preferredFramesPerSecond = 60
        metalView.sampleCount = 1
        return metalView
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.snapshot = snapshot
        nsView.preferredFramesPerSecond = 60
        context.coordinator.installRendererIfNeeded(on: nsView)
    }

    final class Coordinator {
        var snapshot: PlaybackSnapshot
        private var renderer: RibbonRenderer?
        private var didScheduleRendererSetup = false

        init(snapshot: PlaybackSnapshot) {
            self.snapshot = snapshot
        }

        func installRendererIfNeeded(on view: MTKView) {
            guard renderer == nil, !didScheduleRendererSetup else { return }
            didScheduleRendererSetup = true

            Task { @MainActor [weak self, weak view] in
                await Task.yield()
                guard let self,
                      let view,
                      self.renderer == nil,
                      let device = view.device else {
                    return
                }

                #if DEBUG
                self.renderer = RibbonRenderer(device: device, showFPSCounter: false) { [weak self] in
                    self?.playbackState() ?? RibbonRenderer.PlaybackState(
                        isPlaying: false,
                        playbackTime: 0,
                        reduceMotion: false,
                        spectrumStore: nil
                    )
                }
                #else
                self.renderer = RibbonRenderer(device: device) { [weak self] in
                    self?.playbackState() ?? RibbonRenderer.PlaybackState(
                        isPlaying: false,
                        playbackTime: 0,
                        reduceMotion: false,
                        spectrumStore: nil
                    )
                }
                #endif

                view.delegate = self.renderer
            }
        }

        private func playbackState() -> RibbonRenderer.PlaybackState {
            RibbonRenderer.PlaybackState(
                isPlaying: snapshot.isPlaying,
                playbackTime: snapshot.playbackTime,
                reduceMotion: snapshot.reduceMotion,
                spectrumStore: snapshot.spectrumStore
            )
        }
    }
}
