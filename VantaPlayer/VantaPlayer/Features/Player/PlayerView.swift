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

    private var storedDensityMode: DensityMode {
        DensityMode(rawValue: densityModeRawValue) ?? .comfortable
    }

    private var activeDensityMode: DensityMode {
        isCompactMode ? .compact : storedDensityMode
    }

    private var density: DensityMetrics {
        activeDensityMode.metrics
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

    private var sectionTransition: AnyTransition {
        .opacity
    }

    private var minimumPlaylistSectionHeight: CGFloat {
        let minimumRowCount: CGFloat = 3
        let rowBlock = density.playlistRowHeight * minimumRowCount
        let rowPadding = density.playlistRowVerticalPadding * minimumRowCount * 2
        return max(140, rowBlock + rowPadding + 20)
    }

    private var chromeTopSpacerHeight: CGFloat {
        guard isCompactMode else { return chromeInsets.top }
        return min(max(chromeInsets.top - 3, 5), 11)
    }

    private var rootTopPadding: CGFloat {
        isCompactMode ? 2 : density.contentPadding
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(width: chromeInsets.leading, height: 1)
                Spacer(minLength: 0)
            }
            .frame(height: chromeTopSpacerHeight)
            .allowsHitTesting(false)
            .accessibilityHidden(true)

            if isCompactMode {
                compactTransportOnlyStrip
                    .accessibilitySortPriority(6)
            } else {
                NormalPlayerLayoutView(
                    density: density,
                    sectionTransition: sectionTransition,
                    showPlaylist: true,
                    showInspector: isInspectorVisible,
                    headerView: AnyView(nowPlayingHeader),
                    inlineErrorView: inlineErrorBannerView,
                    playlistView: AnyView(normalPlaylistSection),
                    inspectorView: AnyView(inspectorSection),
                    transportView: AnyView(normalTransportStrip)
                )
            }
        }
        .padding(.horizontal, density.contentPadding)
        .padding(.bottom, density.contentPadding)
        .padding(.top, rootTopPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .dropDestination(for: URL.self) { droppedURLs, _ in
            viewModel.importTracks(from: droppedURLs)
            return !droppedURLs.isEmpty
        } isTargeted: { targeted in
            dropTargetActive = targeted
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                if !isCompactMode {
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
            }

            ToolbarItemGroup(placement: .automatic) {
                Button {
                    toggleCompactMode()
                } label: {
                    Image(systemName: isCompactMode ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left")
                }
                .help("Toggle compact mode (⌃⌘C)")
                .accessibilityLabel("Toggle compact mode")
                .accessibilityHint("Switch between compact and normal layouts")

                if !isCompactMode {
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
            if !isPlaylistVisible {
                isPlaylistVisible = true
            }
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
            densityMode: storedDensityMode
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

    private var normalPlaylistSection: some View {
        playlistCard
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(minHeight: minimumPlaylistSectionHeight)
            .accessibilitySortPriority(3)
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
        .vantaCard(
            cornerRadius: density.cardCornerRadius,
            borderColor: dropTargetActive ? Color.accentColor.opacity(0.7) : Color.white.opacity(0.08)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Playlist")
    }

    private var inspectorSection: some View {
        InlineInspectorView(
            currentTrack: viewModel.currentTrack,
            trackCount: viewModel.tracks.count,
            densityMode: storedDensityMode,
            revealInFinder: revealInFinder
        )
        .accessibilitySortPriority(2)
    }

    private var normalTransportStrip: some View {
        transportStrip(isCompact: false)
    }

    private var compactTransportOnlyStrip: some View {
        transportStrip(isCompact: true)
    }

    @ViewBuilder
    private func transportStrip(isCompact: Bool) -> some View {
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

            if isCompact {
                compactTrackMenu
            }

            Text(timeString(scrubPosition))
                .font(.caption)
                .monospacedDigit()
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
                .font(.caption)
                .monospacedDigit()
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
        .vantaCard(cornerRadius: density.cardCornerRadius)
        .accessibilityElement(children: .contain)
    }

    private var compactTrackMenu: some View {
        Menu {
            if viewModel.tracks.isEmpty {
                Text("No tracks in queue")
            } else {
                ForEach(viewModel.tracks) { track in
                    Button {
                        viewModel.playTrack(with: track.id)
                    } label: {
                        if track.id == viewModel.selectedTrackID {
                            Label(track.title, systemImage: "checkmark")
                        } else {
                            Text(track.title)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(compactTrackTitle)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 140, alignment: .leading)

                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.thinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .controlSize(.small)
        .disabled(viewModel.tracks.isEmpty)
        .help("Choose track")
        .accessibilityLabel("Track queue")
        .accessibilityValue(compactTrackTitle)
    }

    private var compactTrackTitle: String {
        guard let selectedTrackID = viewModel.selectedTrackID,
              let selectedTrack = viewModel.tracks.first(where: { $0.id == selectedTrackID }) else {
            return "Queue"
        }
        return selectedTrack.title
    }

    private func applyCompactModeDefaultsOnAppearIfNeeded() {
        guard isCompactMode else { return }

        sectionVisibilityBeforeCompact = SectionVisibilitySnapshot(
            inspectorVisible: isInspectorVisible
        )
        isInspectorVisible = false
    }

    private func handleCompactModeChange(from oldValue: Bool, to newValue: Bool) {
        guard oldValue != newValue else { return }

        if newValue {
            sectionVisibilityBeforeCompact = SectionVisibilitySnapshot(
                inspectorVisible: isInspectorVisible
            )
            isInspectorVisible = false
        } else if let snapshot = sectionVisibilityBeforeCompact {
            isInspectorVisible = snapshot.inspectorVisible
            sectionVisibilityBeforeCompact = nil
        }
    }

    private func toggleCompactMode() {
        isCompactMode.toggle()
    }

    private func toggleInspectorVisibility() {
        guard !isCompactMode else { return }

        if reduceMotion {
            isInspectorVisible.toggle()
        } else {
            withAnimation(.easeOut(duration: 0.12)) {
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
