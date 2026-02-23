import AppKit
import SwiftUI

struct PlayerView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.chromeInsets) private var chromeInsets

    @ObservedObject var viewModel: PlayerViewModel

    @AppStorage(AppStorageKeys.isCompactMode) private var isCompactMode = false
    @AppStorage(AppStorageKeys.isPlaylistVisible) private var isPlaylistVisible = true
    @AppStorage(AppStorageKeys.isInspectorVisible) private var isInspectorVisible = true
    @AppStorage(AppStorageKeys.densityMode) private var densityModeRawValue = DensityMode.comfortable.rawValue

    @State private var dropTargetActive = false
    @State private var scrubPosition: Double = 0
    @State private var isScrubbing = false
    @State private var sectionVisibilityBeforeCompact: SectionVisibilitySnapshot?

    private struct SectionVisibilitySnapshot {
        let playlistVisible: Bool
        let inspectorVisible: Bool
    }

    private static let minuteFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = [.pad]
        return formatter
    }()

    private static let hourFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = [.pad]
        return formatter
    }()

    private var densityMode: DensityMode {
        DensityMode(rawValue: densityModeRawValue) ?? .comfortable
    }

    private var density: DensityMetrics {
        densityMode.metrics
    }

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

    private var sectionAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.18)
    }

    private var sectionTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98, anchor: .top))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(width: chromeInsets.leading, height: 1)
                Spacer(minLength: 0)
            }
            .frame(height: chromeInsets.top)
            .allowsHitTesting(false)
            .accessibilityHidden(true)

            if isCompactMode {
                CompactPlayerLayoutView(
                    density: density,
                    sectionTransition: sectionTransition,
                    showPlaylist: isPlaylistVisible,
                    showInspector: isInspectorVisible,
                    headerView: AnyView(nowPlayingHeader),
                    queuePickerView: AnyView(queuePicker),
                    inlineErrorView: inlineErrorBannerView,
                    playlistView: AnyView(compactPlaylistSection),
                    inspectorView: AnyView(inspectorSection),
                    transportView: AnyView(transportStrip)
                )
            } else {
                NormalPlayerLayoutView(
                    density: density,
                    sectionTransition: sectionTransition,
                    showPlaylist: isPlaylistVisible,
                    showInspector: isInspectorVisible,
                    headerView: AnyView(nowPlayingHeader),
                    inlineErrorView: inlineErrorBannerView,
                    playlistView: AnyView(normalPlaylistSection),
                    inspectorView: AnyView(inspectorSection),
                    transportView: AnyView(transportStrip)
                )
            }
        }
        .padding(density.contentPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .dropDestination(for: URL.self) { droppedURLs, _ in
            viewModel.importTracks(from: droppedURLs)
            return !droppedURLs.isEmpty
        } isTargeted: { targeted in
            dropTargetActive = targeted
        }
        .animation(sectionAnimation, value: isPlaylistVisible)
        .animation(sectionAnimation, value: isInspectorVisible)
        .animation(sectionAnimation, value: viewModel.inlineError != nil)
        .animation(sectionAnimation, value: isCompactMode)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    viewModel.openFilesPanel()
                } label: {
                    Label("Open Files", systemImage: "folder.badge.plus")
                }
                .help("Open audio files (⌘O)")
                .accessibilityLabel("Open audio files")
                .accessibilityHint("Open the import dialog")

                Button {
                    viewModel.openFolderPanel()
                } label: {
                    Label("Import Folder", systemImage: "folder.badge.gearshape")
                }
                .help("Import folder (⌘⇧O)")
                .accessibilityLabel("Import folder")
                .accessibilityHint("Scan a folder and add audio files")
            }

            ToolbarItemGroup(placement: .automatic) {
                Button {
                    toggleCompactMode()
                } label: {
                    Image(systemName: isCompactMode ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }
                .help("Toggle compact mode (⌃⌘C)")
                .accessibilityLabel("Toggle compact mode")
                .accessibilityHint("Switch between compact and normal layouts")

                Button {
                    togglePlaylistVisibility()
                } label: {
                    Image(systemName: isPlaylistVisible ? "list.bullet.rectangle.fill" : "list.bullet.rectangle")
                }
                .help("Toggle playlist (⌥⌘S)")
                .accessibilityLabel("Toggle playlist")
                .accessibilityHint("Show or hide the playlist section")

                Button {
                    toggleInspectorVisibility()
                } label: {
                    Image(systemName: isInspectorVisible ? "info.circle.fill" : "info.circle")
                }
                .help("Toggle inspector (⌥⌘I)")
                .accessibilityLabel("Toggle inspector")
                .accessibilityHint("Show or hide the inspector section")
            }
        }
        .toolbarBackground(.hidden, for: .windowToolbar)
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
            applyCompactModeDefaultsOnAppearIfNeeded()
        }
        .onChange(of: isCompactMode) { oldValue, newValue in
            handleCompactModeChange(from: oldValue, to: newValue)
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
        .onChange(of: viewModel.selectedTrackID) { _, newValue in
            guard let newValue else { return }
            viewModel.playTrack(with: newValue)
        }
    }

    private var nowPlayingHeader: some View {
        NowPlayingHeaderView(
            currentTrack: viewModel.currentTrack,
            isPlaying: viewModel.isPlaying,
            playbackDuration: viewModel.playbackDuration,
            isImporting: viewModel.isImporting,
            densityMode: densityMode
        )
    }

    private var inlineErrorBannerView: AnyView? {
        guard let inlineError = viewModel.inlineError else {
            return nil
        }

        return AnyView(
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
        )
    }

    private var queuePicker: some View {
        QueuePickerView(
            tracks: viewModel.tracks,
            selectedTrackID: viewModel.selectedTrackID,
            densityMode: densityMode
        ) { trackID in
            viewModel.playTrack(with: trackID)
        }
    }

    private var normalPlaylistSection: some View {
        playlistCard
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilitySortPriority(3)
    }

    private var compactPlaylistSection: some View {
        playlistCard
            .frame(maxWidth: .infinity)
            .frame(maxHeight: density.compactPlaylistMaxHeight)
            .accessibilitySortPriority(2)
    }

    private var playlistCard: some View {
        VStack(spacing: 0) {
            if viewModel.isImporting {
                ImportProgressStrip(
                    label: viewModel.importProgressLabel ?? "Importing…",
                    fraction: viewModel.importProgressFraction
                )
            }

            if viewModel.tracks.isEmpty {
                PlaylistEmptyStateView(
                    isDropTargeted: dropTargetActive,
                    reduceMotion: reduceMotion,
                    isRestoringSession: viewModel.isRestoringSession
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $viewModel.selectedTrackID) {
                    ForEach(viewModel.tracks) { track in
                        PlaylistRowView(
                            title: track.title,
                            duration: track.duration.map(timeString),
                            isPlayable: track.isPlayable,
                            density: density
                        )
                        .tag(track.id)
                        .contentShape(Rectangle())
                        .contextMenu {
                            Button("Remove") {
                                viewModel.removeTrack(id: track.id)
                            }
                        }
                        .accessibilityHint(track.isPlayable ? "Play this track" : "Track cannot be played")
                    }
                    .onMove(perform: viewModel.moveTracks(from:to:))
                }
                .listStyle(.inset(alternatesRowBackgrounds: false))
                .scrollContentBackground(.hidden)
                .background(Color.clear)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: density.cardCornerRadius, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: density.cardCornerRadius, style: .continuous)
                .strokeBorder(dropTargetActive ? Color.accentColor.opacity(0.7) : Color.white.opacity(0.08), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: density.cardCornerRadius, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Playlist")
    }

    private var inspectorSection: some View {
        InlineInspectorView(
            currentTrack: viewModel.currentTrack,
            trackCount: viewModel.tracks.count,
            densityMode: densityMode,
            revealInFinder: revealInFinder
        )
        .accessibilitySortPriority(2)
    }

    private var transportStrip: some View {
        HStack(spacing: density.transportSpacing) {
            Button {
                viewModel.playPrevious()
            } label: {
                Image(systemName: "backward.fill")
            }
            .buttonStyle(.borderless)
            .help("Previous track")
            .accessibilityLabel("Previous track")
            .disabled(!viewModel.hasTracks)

            Button {
                viewModel.togglePlayPause()
            } label: {
                Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                    .font(.body.weight(.semibold))
                    .frame(width: 16)
            }
            .buttonStyle(.plain)
            .help("Play or pause")
            .accessibilityLabel(viewModel.isPlaying ? "Pause" : "Play")
            .disabled(!viewModel.hasTracks)

            Button {
                viewModel.playNext()
            } label: {
                Image(systemName: "forward.fill")
            }
            .buttonStyle(.borderless)
            .help("Next track")
            .accessibilityLabel("Next track")
            .disabled(!viewModel.hasTracks)

            Text(timeString(scrubPosition))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: density.transportTimeWidth, alignment: .trailing)

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
            .help("Seek")
            .accessibilityLabel("Playback position")
            .disabled(!viewModel.hasTracks)

            Text(timeString(viewModel.playbackDuration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: density.transportTimeWidth, alignment: .leading)

            Image(systemName: "speaker.fill")
                .foregroundStyle(.secondary)

            Slider(value: volumeBinding, in: 0...1)
                .frame(width: density.volumeSliderWidth)
                .help("Volume")
                .accessibilityLabel("Volume")
        }
        .controlSize(density.controlSize)
        .padding(.horizontal, density.transportHorizontalPadding)
        .padding(.vertical, density.transportVerticalPadding)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: density.cardCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: density.cardCornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }

    private func applyCompactModeDefaultsOnAppearIfNeeded() {
        guard isCompactMode else { return }

        sectionVisibilityBeforeCompact = SectionVisibilitySnapshot(
            playlistVisible: isPlaylistVisible,
            inspectorVisible: isInspectorVisible
        )
        isPlaylistVisible = false
        isInspectorVisible = false
    }

    private func handleCompactModeChange(from oldValue: Bool, to newValue: Bool) {
        guard oldValue != newValue else { return }

        let updates = {
            if newValue {
                sectionVisibilityBeforeCompact = SectionVisibilitySnapshot(
                    playlistVisible: isPlaylistVisible,
                    inspectorVisible: isInspectorVisible
                )
                isPlaylistVisible = false
                isInspectorVisible = false
            } else if let snapshot = sectionVisibilityBeforeCompact {
                isPlaylistVisible = snapshot.playlistVisible
                isInspectorVisible = snapshot.inspectorVisible
                sectionVisibilityBeforeCompact = nil
            }
        }

        if reduceMotion {
            updates()
        } else {
            withAnimation(.easeInOut(duration: 0.18)) {
                updates()
            }
        }
    }

    private func toggleCompactMode() {
        if reduceMotion {
            isCompactMode.toggle()
        } else {
            withAnimation(.easeInOut(duration: 0.18)) {
                isCompactMode.toggle()
            }
        }
    }

    private func togglePlaylistVisibility() {
        if reduceMotion {
            isPlaylistVisible.toggle()
        } else {
            withAnimation(.easeInOut(duration: 0.18)) {
                isPlaylistVisible.toggle()
            }
        }
    }

    private func toggleInspectorVisibility() {
        if reduceMotion {
            isInspectorVisible.toggle()
        } else {
            withAnimation(.easeInOut(duration: 0.18)) {
                isInspectorVisible.toggle()
            }
        }
    }

    private func revealInFinder(_ fileURL: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    private func timeString(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }

        if seconds >= 3600 {
            return Self.hourFormatter.string(from: seconds) ?? "0:00"
        }

        return Self.minuteFormatter.string(from: seconds) ?? "0:00"
    }
}

private struct NormalPlayerLayoutView: View {
    let density: DensityMetrics
    let sectionTransition: AnyTransition
    let showPlaylist: Bool
    let showInspector: Bool
    let headerView: AnyView
    let inlineErrorView: AnyView?
    let playlistView: AnyView
    let inspectorView: AnyView
    let transportView: AnyView

    var body: some View {
        VStack(spacing: density.sectionSpacing) {
            headerView
                .accessibilitySortPriority(4)

            if let inlineErrorView {
                inlineErrorView
                    .transition(sectionTransition)
            }

            if showPlaylist {
                playlistView
                    .transition(sectionTransition)
                    .accessibilitySortPriority(3)
            }

            if showInspector {
                inspectorView
                    .transition(sectionTransition)
                    .accessibilitySortPriority(2)
            }

            transportView
                .accessibilitySortPriority(1)
        }
    }
}

private struct CompactPlayerLayoutView: View {
    let density: DensityMetrics
    let sectionTransition: AnyTransition
    let showPlaylist: Bool
    let showInspector: Bool
    let headerView: AnyView
    let queuePickerView: AnyView
    let inlineErrorView: AnyView?
    let playlistView: AnyView
    let inspectorView: AnyView
    let transportView: AnyView

    var body: some View {
        VStack(spacing: density.sectionSpacing) {
            headerView
                .accessibilitySortPriority(6)

            queuePickerView
                .accessibilitySortPriority(5)

            if let inlineErrorView {
                inlineErrorView
                    .transition(sectionTransition)
            }

            transportView
                .accessibilitySortPriority(4)

            if showPlaylist {
                playlistView
                    .transition(sectionTransition)
                    .accessibilitySortPriority(3)
            }

            if showInspector {
                inspectorView
                    .transition(sectionTransition)
                    .accessibilitySortPriority(2)
            }
        }
    }
}

private struct PlaylistRowView: View {
    let title: String
    let duration: String?
    let isPlayable: Bool
    let density: DensityMetrics

    var body: some View {
        HStack(spacing: density.playlistRowSpacing) {
            Text(title)
                .lineLimit(1)
                .foregroundStyle(isPlayable ? .primary : .secondary)

            Spacer(minLength: density.playlistRowSpacing / 2)

            if let duration {
                Text(duration)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, density.playlistRowVerticalPadding)
        .frame(minHeight: density.playlistRowHeight, alignment: .center)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(duration ?? "Unknown length")
    }
}

private struct PlaylistEmptyStateView: View {
    let isDropTargeted: Bool
    let reduceMotion: Bool
    let isRestoringSession: Bool

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)

            Text("Drop audio here or press ⌘O")
                .font(.headline)

            if isRestoringSession {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Restoring previous session…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .contentShape(Rectangle())
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isDropTargeted ? Color.accentColor.opacity(0.7) : Color.clear,
                    lineWidth: isDropTargeted ? 2 : 0
                )
                .padding(12)
        )
        .scaleEffect(isDropTargeted && !reduceMotion ? 1.01 : 1)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.14), value: isDropTargeted)
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
                Button("Remove", action: onRemove)
                    .buttonStyle(.link)
            }

            Button("Dismiss", action: onDismiss)
                .buttonStyle(.link)
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }
}

private struct ImportProgressStrip: View {
    let label: String
    let fraction: Double?

    var body: some View {
        HStack(spacing: 8) {
            if let fraction {
                ProgressView(value: fraction)
                    .controlSize(.small)
                    .frame(width: 72)
            } else {
                ProgressView()
                    .controlSize(.small)
            }

            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
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
        context.coordinator.start()
    }

    final class Coordinator {
        var onKeyDown: (NSEvent) -> NSEvent?
        private var monitorToken: Any?

        init(onKeyDown: @escaping (NSEvent) -> NSEvent?) {
            self.onKeyDown = onKeyDown
        }

        deinit {
            if let monitorToken {
                NSEvent.removeMonitor(monitorToken)
            }
        }

        func start() {
            guard monitorToken == nil else { return }
            monitorToken = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                return self.onKeyDown(event)
            }
        }
    }
}
