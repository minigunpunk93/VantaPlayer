import AppKit
import SwiftUI

struct PlayerView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var viewModel: PlayerViewModel

    @State private var dropTargetActive = false
    @State private var scrubPosition: Double = 0
    @State private var isScrubbing = false

    private var seekRange: ClosedRange<Double> {
        let duration = max(viewModel.playbackDuration, 1)
        return 0...duration
    }

    private var volumeBinding: Binding<Double> {
        Binding(
            get: { Double(viewModel.volume) },
            set: { viewModel.setVolume(Float($0)) }
        )
    }

    var body: some View {
        NavigationSplitView {
            PlaylistSidebarView(
                tracks: viewModel.tracks,
                selection: $viewModel.selectedTrackID,
                onSelect: viewModel.playTrack(with:),
                onMove: viewModel.moveTracks(from:to:)
            )
            .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 300)
        } content: {
            contentColumn
        } detail: {
            inspectorColumn
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    viewModel.openFilesPanel()
                } label: {
                    Label("Open", systemImage: "folder.badge.plus")
                }
                .accessibilityLabel("Open audio files")
                .accessibilityHint("Open the import dialog")
            }

            ToolbarItemGroup(placement: .principal) {
                Button {
                    viewModel.playPrevious()
                } label: {
                    Image(systemName: "backward.end.fill")
                }
                .accessibilityLabel("Previous track")
                .accessibilityHint("Play the previous track in the playlist")
                .disabled(!viewModel.hasTracks)

                Button {
                    viewModel.togglePlayPause()
                } label: {
                    Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                }
                .accessibilityLabel(viewModel.isPlaying ? "Pause" : "Play")
                .accessibilityHint("Toggle playback")
                .disabled(!viewModel.hasTracks)

                Button {
                    viewModel.playNext()
                } label: {
                    Image(systemName: "forward.end.fill")
                }
                .accessibilityLabel("Next track")
                .accessibilityHint("Play the next track in the playlist")
                .disabled(!viewModel.hasTracks)
            }
        }
        .background(
            KeyboardEventMonitor { event in
                viewModel.handleKeyDown(event)
            }
            .frame(width: 0, height: 0)
        )
        .task {
            viewModel.bootstrapAfterFirstFrame()
        }
        .onAppear {
            scrubPosition = viewModel.playbackTime
        }
        .onChange(of: viewModel.playbackTime) { _, newValue in
            guard !isScrubbing else { return }
            scrubPosition = newValue
        }
        .onChange(of: viewModel.playbackDuration) { _, newDuration in
            if scrubPosition > newDuration {
                scrubPosition = newDuration
            }
        }
    }

    private var contentColumn: some View {
        ZStack(alignment: .bottom) {
            VisualizerView(
                snapshot: .init(
                    isPlaying: viewModel.isPlaying,
                    playbackTime: viewModel.playbackTime,
                    energy: viewModel.visualizerEnergy(reduceMotion: reduceMotion),
                    reduceMotion: reduceMotion
                )
            )
            .overlay(alignment: .topLeading) {
                if let inlineError = viewModel.inlineError {
                    InlineErrorBanner(
                        message: inlineError.message,
                        showRemoveAction: inlineError.trackID != nil,
                        onRemove: {
                            if let trackID = inlineError.trackID {
                                viewModel.removeTrack(id: trackID)
                            }
                        },
                        onDismiss: viewModel.dismissInlineError
                    )
                    .padding(16)
                }
            }
            .overlay(alignment: .topTrailing) {
                if viewModel.isImporting {
                    LoadingChip()
                        .padding(16)
                }
            }
            .overlay {
                if viewModel.tracks.isEmpty {
                    EmptyStateView(isDropTargeted: dropTargetActive, reduceMotion: reduceMotion)
                }
            }
            .accessibilityLabel("Visualizer")
            .accessibilityHint("Background visualization responding to playback state")
            .accessibilitySortPriority(1)

            transportBar
                .padding(20)
                .accessibilitySortPriority(2)
        }
        .dropDestination(for: URL.self) { droppedURLs, _ in
            viewModel.importTracks(from: droppedURLs)
            return !droppedURLs.isEmpty
        } isTargeted: { targeted in
            dropTargetActive = targeted
        }
    }

    private var transportBar: some View {
        HStack(spacing: 10) {
            Button {
                viewModel.playPrevious()
            } label: {
                Image(systemName: "backward.fill")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Previous track")
            .accessibilityHint("Play previous track")
            .disabled(!viewModel.hasTracks)

            Button {
                viewModel.togglePlayPause()
            } label: {
                Image(systemName: viewModel.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 22, weight: .semibold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(viewModel.isPlaying ? "Pause" : "Play")
            .accessibilityHint("Toggle playback")
            .disabled(!viewModel.hasTracks)

            Button {
                viewModel.playNext()
            } label: {
                Image(systemName: "forward.fill")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Next track")
            .accessibilityHint("Play next track")
            .disabled(!viewModel.hasTracks)

            Text(timeString(scrubPosition))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .trailing)

            Slider(
                value: $scrubPosition,
                in: seekRange,
                onEditingChanged: { editing in
                    isScrubbing = editing
                    if !editing {
                        viewModel.seek(to: scrubPosition)
                    }
                }
            )
            .accessibilityLabel("Playback position")
            .accessibilityHint("Adjust the current playhead position")
            .disabled(!viewModel.hasTracks)

            Text(timeString(viewModel.playbackDuration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .leading)

            Image(systemName: "speaker.fill")
                .foregroundStyle(.secondary)

            Slider(value: volumeBinding, in: 0...1)
                .frame(width: 110)
                .accessibilityLabel("Volume")
                .accessibilityHint("Adjust playback volume")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.08))
        )
        .frame(maxWidth: 760)
        .accessibilityElement(children: .contain)
    }

    private var inspectorColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Inspector")
                .font(.headline)

            if let currentTrack = viewModel.currentTrack {
                Text(currentTrack.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(2)

                if let duration = currentTrack.duration, duration > 0 {
                    Label(timeString(duration), systemImage: "clock")
                        .foregroundStyle(.secondary)
                } else {
                    Label("Unknown length", systemImage: "clock")
                        .foregroundStyle(.secondary)
                }

                Label(currentTrack.url.lastPathComponent, systemImage: "doc")
                    .lineLimit(2)
                    .foregroundStyle(.secondary)
            } else {
                Text("Select a track to see details.")
                    .foregroundStyle(.secondary)
            }

            Divider()

            Label("\(viewModel.tracks.count) tracks", systemImage: "music.note.list")
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(18)
        .accessibilityElement(children: .contain)
    }

    private func timeString(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }

        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute, .second] : [.minute, .second]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = [.pad]

        return formatter.string(from: seconds) ?? "0:00"
    }
}

private struct EmptyStateView: View {
    let isDropTargeted: Bool
    let reduceMotion: Bool

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)

            Text("Drop audio here or press ⌘O")
                .font(.title3.weight(.medium))

            Text("Supports wav, mp3, m4a, aiff, and flac (if available).")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(maxWidth: 460)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(
                    isDropTargeted ? .white.opacity(0.55) : .white.opacity(0.12),
                    lineWidth: isDropTargeted ? 2 : 1
                )
        )
        .scaleEffect(isDropTargeted && !reduceMotion ? 1.02 : 1)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: isDropTargeted)
        .padding(24)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Drop audio here or press command O")
        .accessibilityHint("Import files to start playback")
    }
}

private struct InlineErrorBanner: View {
    let message: String
    let showRemoveAction: Bool
    let onRemove: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)

            Text(message)
                .font(.subheadline)
                .lineLimit(2)

            Spacer(minLength: 8)

            if showRemoveAction {
                Button("Remove from playlist", action: onRemove)
            }

            Button("Dismiss", action: onDismiss)
                .buttonStyle(.link)
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.white.opacity(0.12))
        )
        .frame(maxWidth: 520)
    }
}

private struct LoadingChip: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Importing…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: Capsule())
    }
}

private struct KeyboardEventMonitor: NSViewRepresentable {
    let onKeyDown: (NSEvent) -> NSEvent?

    func makeCoordinator() -> Coordinator {
        Coordinator(onKeyDown: onKeyDown)
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.start()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onKeyDown = onKeyDown
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator {
        var onKeyDown: (NSEvent) -> NSEvent?
        private var monitor: Any?

        init(onKeyDown: @escaping (NSEvent) -> NSEvent?) {
            self.onKeyDown = onKeyDown
        }

        func start() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                return self.onKeyDown(event)
            }
        }

        func stop() {
            guard let monitor else { return }
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}
