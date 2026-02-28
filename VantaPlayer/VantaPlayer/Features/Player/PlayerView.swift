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
    @State private var lastNonZeroVolume: Double = 0.8
    @State private var volumeFadeTask: Task<Void, Never>?
    @State private var isVolumeFadeInProgress = false
    @State private var sectionVisibilityBeforeCompact: SectionVisibilitySnapshot?
    @State private var playlistDraggingTrackID: Track.ID?
    @State private var playlistDragTranslation: CGFloat = 0
    @State private var playlistDragStartIndex: Int?
    @State private var playlistDragTargetIndex: Int?

    private let volumeMuteThreshold: Double = 0.0001
    private let defaultUnmutedVolume: Double = 0.8
    private let volumeFadeDuration: TimeInterval = 0.5
    private let volumeFadeSteps: Int = 20

    private struct SectionVisibilitySnapshot {
        let inspectorVisible: Bool
    }

    private var storedDensityMode: DensityMode {
        DensityMode(rawValue: densityModeRawValue) ?? .comfortable
    }

    private var isEffectiveCompactMode: Bool {
        isCompactMode
    }

    private var shouldShowInspectorInNormalLayout: Bool {
        isInspectorVisible && !isEffectiveCompactMode
    }

    private var activeDensityMode: DensityMode {
        isEffectiveCompactMode ? .compact : storedDensityMode
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
            set: { newValue in
                let clampedValue = min(max(newValue, 0), 1)
                cancelVolumeFadeAnimation()
                if clampedValue > volumeMuteThreshold {
                    lastNonZeroVolume = clampedValue
                }
                viewModel.setVolume(Float(clampedValue))
            }
        )
    }

    private var isVolumeMuted: Bool {
        Double(viewModel.volume) <= volumeMuteThreshold
    }

    private var volumeIconName: String {
        isVolumeMuted ? "speaker.slash.fill" : "speaker.fill"
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
        guard isEffectiveCompactMode else { return chromeInsets.top }
        return min(max(chromeInsets.top - 3, 5), 11)
    }

    private var rootTopPadding: CGFloat {
        isEffectiveCompactMode ? 2 : density.contentPadding
    }

    private var playlistRowStride: CGFloat {
        density.playlistRowHeight + 4
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

            if isEffectiveCompactMode {
                compactTransportOnlyStrip
                    .accessibilitySortPriority(6)
            } else {
                NormalPlayerLayoutView(
                    density: density,
                    sectionTransition: sectionTransition,
                    showPlaylist: true,
                    showInspector: shouldShowInspectorInNormalLayout,
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
                if !isEffectiveCompactMode {
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
                    Image(systemName: isEffectiveCompactMode ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left")
                }
                .help("Toggle compact mode")
                .accessibilityLabel("Toggle compact mode")
                .accessibilityHint("Switch between compact and normal layouts")

                if !isEffectiveCompactMode {
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
            if Double(viewModel.volume) > volumeMuteThreshold {
                lastNonZeroVolume = Double(viewModel.volume)
            }
            applyCompactModeDefaultsOnAppearIfNeeded()
        }
        .onDisappear {
            cancelVolumeFadeAnimation()
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
        .onChange(of: viewModel.volume) { _, newValue in
            let normalized = Double(newValue)
            if !isVolumeFadeInProgress && normalized > volumeMuteThreshold {
                lastNonZeroVolume = normalized
            }
        }
    }

    private var transportSideColumnWidth: CGFloat {
        max(108, density.volumeSliderWidth + 24)
    }

    private var transportDisplayTrack: Track? {
        viewModel.playingTrack ?? viewModel.currentTrack
    }

    private var transportTitleText: String {
        transportDisplayTrack?.title ?? "No Track Selected"
    }

    private var transportArtistText: String? {
        guard let artist = transportDisplayTrack?.artist?.trimmingCharacters(in: .whitespacesAndNewlines),
              !artist.isEmpty else {
            return nil
        }
        return artist
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
                ScrollView {
                    LazyVStack(spacing: 4) {
                        if playlistInsertionSlot(for: viewModel.tracks.count) == 0 {
                            PlaylistInsertionIndicatorView()
                        }
                        ForEach(Array(viewModel.tracks.enumerated()), id: \.element.id) { index, track in
                            let isSelected = viewModel.selectedTrackID == track.id
                            let isNowPlayingTrack = viewModel.playingTrack?.id == track.id && viewModel.isPlaying
                            let isDraggingRow = playlistDraggingTrackID == track.id
                            PlaylistRowView(
                                number: index + 1,
                                title: track.title,
                                duration: track.duration.map(timeString),
                                isPlayable: track.isPlayable,
                                isSelected: isSelected,
                                isNowPlayingTrack: isNowPlayingTrack,
                                isDragging: isDraggingRow,
                                density: density
                            )
                            .contentShape(Rectangle())
                            .offset(y: playlistRowOffset(for: index, trackID: track.id))
                            .zIndex(isDraggingRow ? 100 : 0)
                            .contextMenu {
                                Button("Remove") {
                                    viewModel.removeTrack(id: track.id)
                                }
                            }
                            .onTapGesture {
                                viewModel.selectedTrackID = track.id
                            }
                            .simultaneousGesture(
                                TapGesture(count: 2).onEnded {
                                    viewModel.selectedTrackID = track.id
                                    viewModel.playTrack(with: track.id)
                                }
                            )
                            .simultaneousGesture(
                                DragGesture(minimumDistance: 4)
                                    .onChanged { value in
                                        handlePlaylistDragChanged(trackID: track.id, translationY: value.translation.height)
                                    }
                                    .onEnded { _ in
                                        handlePlaylistDragEnded(trackID: track.id)
                                    }
                            )
                            .accessibilityHint(track.isPlayable ? "Play this track" : "Track cannot be played")

                            if playlistInsertionSlot(for: viewModel.tracks.count) == index + 1 {
                                PlaylistInsertionIndicatorView()
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
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
        VStack(spacing: max(6, density.transportSpacing - 2)) {
            HStack(spacing: density.transportSpacing) {
                Text(timeString(scrubPosition))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: density.transportTimeWidth, alignment: .center)

                SeekBar(
                    value: scrubPosition,
                    range: seekRange,
                    isEnabled: viewModel.hasTracks,
                    onScrubBegan: {
                        isScrubbing = true
                    },
                    onScrubChanged: { newValue in
                        scrubPosition = newValue
                    },
                    onScrubEnded: { finalValue in
                        scrubPosition = finalValue
                        isScrubbing = false
                        viewModel.seek(to: finalValue)
                    }
                )
                .help("Seek")
                .accessibilityLabel("Playback position")
                .frame(maxWidth: .infinity)

                Text(timeString(viewModel.playbackDuration))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: density.transportTimeWidth, alignment: .center)
            }
            .frame(maxWidth: .infinity)
            .layoutPriority(1)

            HStack(spacing: density.transportSpacing) {
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
                }
                .frame(width: transportSideColumnWidth, alignment: .leading)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(transportTitleText)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(viewModel.currentTrack == nil ? .secondary : .primary)

                    if let artist = transportArtistText {
                        Text("•")
                            .font(.caption)
                            .foregroundStyle(.tertiary)

                        Text(artist)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(transportArtistText.map { "\(transportTitleText), \($0)" } ?? transportTitleText)

                HStack(spacing: density.transportSpacing) {
                    volumeToggleButton

                    Slider(value: volumeBinding, in: 0...1)
                        .frame(width: density.volumeSliderWidth)
                        .help("Volume")
                        .accessibilityLabel("Volume")
                }
                .frame(width: transportSideColumnWidth, alignment: .trailing)
            }
        }
        .controlSize(density.controlSize)
        .padding(.horizontal, max(6, density.transportHorizontalPadding - 2))
        .padding(.vertical, density.transportVerticalPadding)
        .vantaCard(cornerRadius: density.cardCornerRadius)
        .accessibilityElement(children: .contain)
    }

    private var compactTransportOnlyStrip: some View {
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

            compactTrackMenu

            Text(timeString(scrubPosition))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: density.transportTimeWidth, alignment: .center)

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
                .frame(width: density.transportTimeWidth, alignment: .center)

            volumeToggleButton

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

    private var volumeToggleButton: some View {
        Button {
            toggleMuteVolume()
        } label: {
            Image(systemName: volumeIconName)
                .foregroundStyle(.secondary)
                .frame(width: 13)
        }
        .buttonStyle(.plain)
        .help(isVolumeMuted ? "Unmute" : "Mute")
        .accessibilityLabel(isVolumeMuted ? "Unmute" : "Mute")
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
        guard !isEffectiveCompactMode else { return }

        if reduceMotion {
            isInspectorVisible.toggle()
        } else {
            withAnimation(.easeOut(duration: 0.12)) {
                isInspectorVisible.toggle()
            }
        }
    }

    private func toggleMuteVolume() {
        let currentVolume = Double(viewModel.volume)

        if currentVolume > volumeMuteThreshold {
            lastNonZeroVolume = currentVolume
            animateVolume(to: 0)
            return
        }

        let restoredVolume = lastNonZeroVolume > volumeMuteThreshold
            ? min(max(lastNonZeroVolume, 0), 1)
            : defaultUnmutedVolume
        animateVolume(to: restoredVolume)
    }

    private func animateVolume(to targetVolume: Double) {
        let clampedTarget = min(max(targetVolume, 0), 1)
        cancelVolumeFadeAnimation()

        let startingVolume = Double(viewModel.volume)
        guard abs(startingVolume - clampedTarget) > volumeMuteThreshold else {
            viewModel.setVolume(Float(clampedTarget))
            if clampedTarget > volumeMuteThreshold {
                lastNonZeroVolume = clampedTarget
            }
            return
        }

        isVolumeFadeInProgress = true
        let stepDelay = UInt64((volumeFadeDuration / Double(volumeFadeSteps)) * 1_000_000_000)

        volumeFadeTask = Task { @MainActor in
            defer {
                isVolumeFadeInProgress = false
                volumeFadeTask = nil
            }

            for step in 1...volumeFadeSteps {
                if Task.isCancelled { return }

                let progress = Double(step) / Double(volumeFadeSteps)
                let easedProgress = progress * progress * (3 - (2 * progress))
                let interpolatedVolume = startingVolume + (clampedTarget - startingVolume) * easedProgress
                viewModel.setVolume(Float(interpolatedVolume))

                if step < volumeFadeSteps {
                    try? await Task.sleep(nanoseconds: stepDelay)
                }
            }

            viewModel.setVolume(Float(clampedTarget))
            if clampedTarget > volumeMuteThreshold {
                lastNonZeroVolume = clampedTarget
            }
        }
    }

    private func cancelVolumeFadeAnimation() {
        volumeFadeTask?.cancel()
        volumeFadeTask = nil
        isVolumeFadeInProgress = false
    }

    private func handlePlaylistDragChanged(trackID: Track.ID, translationY: CGFloat) {
        if playlistDraggingTrackID == nil {
            playlistDraggingTrackID = trackID
            playlistDragTranslation = 0
            playlistDragStartIndex = viewModel.tracks.firstIndex(where: { $0.id == trackID })
            playlistDragTargetIndex = playlistDragStartIndex
        }

        guard playlistDraggingTrackID == trackID,
              let startIndex = playlistDragStartIndex else {
            return
        }

        playlistDragTranslation = translationY

        let dragStep = Int((translationY / playlistRowStride).rounded())
        let maxIndex = max(viewModel.tracks.count - 1, 0)
        let nextTargetIndex = min(max(startIndex + dragStep, 0), maxIndex)
        if playlistDragTargetIndex != nextTargetIndex {
            withAnimation(.interactiveSpring(response: 0.2, dampingFraction: 0.88)) {
                playlistDragTargetIndex = nextTargetIndex
            }
        }
    }

    private func handlePlaylistDragEnded(trackID: Track.ID) {
        guard playlistDraggingTrackID == trackID,
              let sourceIndex = playlistDragStartIndex else {
            return
        }

        withAnimation(.easeOut(duration: 0.12)) {
            playlistDragTranslation = 0
        }

        let targetIndex = playlistDragTargetIndex ?? sourceIndex
        if targetIndex != sourceIndex {
            let destinationIndex = targetIndex > sourceIndex ? targetIndex + 1 : targetIndex
            withAnimation(.interactiveSpring(response: 0.24, dampingFraction: 0.88)) {
                viewModel.moveTrack(id: trackID, to: destinationIndex, persist: false)
            }
            viewModel.persistTrackOrder()
        }

        playlistDraggingTrackID = nil
        playlistDragStartIndex = nil
        playlistDragTargetIndex = nil
    }

    private func playlistRowOffset(for rowIndex: Int, trackID: Track.ID) -> CGFloat {
        guard let draggingTrackID = playlistDraggingTrackID,
              let sourceIndex = playlistDragStartIndex,
              let targetIndex = playlistDragTargetIndex else {
            return 0
        }

        if trackID == draggingTrackID {
            return playlistDragTranslation
        }

        if sourceIndex < targetIndex, rowIndex > sourceIndex, rowIndex <= targetIndex {
            return -playlistRowStride
        }

        if sourceIndex > targetIndex, rowIndex >= targetIndex, rowIndex < sourceIndex {
            return playlistRowStride
        }

        return 0
    }

    private func playlistInsertionSlot(for trackCount: Int) -> Int? {
        guard let sourceIndex = playlistDragStartIndex,
              let targetIndex = playlistDragTargetIndex,
              sourceIndex != targetIndex else {
            return nil
        }

        let rawSlot = sourceIndex < targetIndex ? targetIndex + 1 : targetIndex
        return min(max(rawSlot, 0), trackCount)
    }

    private func revealInFinder(_ fileURL: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    private func timeString(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }

        let clampedSeconds = max(0, Int(seconds))
        let hours = clampedSeconds / 3600
        let minutes = (clampedSeconds % 3600) / 60
        let remainingSeconds = clampedSeconds % 60

        let paddedMinutes = minutes < 10 ? "0\(minutes)" : "\(minutes)"
        let paddedSeconds = remainingSeconds < 10 ? "0\(remainingSeconds)" : "\(remainingSeconds)"

        if hours > 0 {
            return "\(hours):\(paddedMinutes):\(paddedSeconds)"
        }

        return "\(minutes):\(paddedSeconds)"
    }
}

private struct SeekBar: View {
    let value: Double
    let range: ClosedRange<Double>
    let isEnabled: Bool
    let onScrubBegan: () -> Void
    let onScrubChanged: (Double) -> Void
    let onScrubEnded: (Double) -> Void

    private var normalizedProgress: CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        let clampedValue = min(max(value, range.lowerBound), range.upperBound)
        return CGFloat((clampedValue - range.lowerBound) / span)
    }

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)

            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.14))

                Capsule(style: .continuous)
                    .fill(Color.accentColor)
                    .frame(width: width * normalizedProgress)
            }
            .frame(height: 8)
            .contentShape(Rectangle())
            .overlay {
                SeekBarMouseCaptureLayer(
                    range: range,
                    isEnabled: isEnabled,
                    onScrubBegan: onScrubBegan,
                    onScrubChanged: onScrubChanged,
                    onScrubEnded: onScrubEnded
                )
            }
        }
        .frame(height: 8)
        .opacity(isEnabled ? 1 : 0.55)
        .accessibilityElement(children: .ignore)
        .accessibilityAdjustableAction { direction in
            guard isEnabled else { return }
            let step = max((range.upperBound - range.lowerBound) / 20, 1)
            let adjustedValue: Double

            switch direction {
            case .increment:
                adjustedValue = min(max(value + step, range.lowerBound), range.upperBound)
            case .decrement:
                adjustedValue = min(max(value - step, range.lowerBound), range.upperBound)
            @unknown default:
                return
            }

            onScrubBegan()
            onScrubChanged(adjustedValue)
            onScrubEnded(adjustedValue)
        }
    }
}

private struct SeekBarMouseCaptureLayer: NSViewRepresentable {
    let range: ClosedRange<Double>
    let isEnabled: Bool
    let onScrubBegan: () -> Void
    let onScrubChanged: (Double) -> Void
    let onScrubEnded: (Double) -> Void

    func makeNSView(context: Context) -> SeekBarMouseCaptureView {
        let view = SeekBarMouseCaptureView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        return view
    }

    func updateNSView(_ nsView: SeekBarMouseCaptureView, context: Context) {
        nsView.range = range
        nsView.isCaptureEnabled = isEnabled
        nsView.onScrubBegan = onScrubBegan
        nsView.onScrubChanged = onScrubChanged
        nsView.onScrubEnded = onScrubEnded
    }
}

private final class SeekBarMouseCaptureView: NSView {
    var range: ClosedRange<Double> = 0...1
    var isCaptureEnabled = true
    var onScrubBegan: (() -> Void)?
    var onScrubChanged: ((Double) -> Void)?
    var onScrubEnded: ((Double) -> Void)?

    private var isTrackingSeek = false

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isCaptureEnabled else { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        guard isCaptureEnabled else {
            super.mouseDown(with: event)
            return
        }

        isTrackingSeek = true
        onScrubBegan?()
        let value = resolvedValue(from: event)
        onScrubChanged?(value)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isCaptureEnabled, isTrackingSeek else {
            super.mouseDragged(with: event)
            return
        }

        let value = resolvedValue(from: event)
        onScrubChanged?(value)
    }

    override func mouseUp(with event: NSEvent) {
        guard isCaptureEnabled, isTrackingSeek else {
            super.mouseUp(with: event)
            return
        }

        let value = resolvedValue(from: event)
        onScrubChanged?(value)
        onScrubEnded?(value)
        isTrackingSeek = false
    }

    override func mouseExited(with event: NSEvent) {
        guard isCaptureEnabled, isTrackingSeek else {
            super.mouseExited(with: event)
            return
        }

        let value = resolvedValue(from: event)
        onScrubChanged?(value)
        onScrubEnded?(value)
        isTrackingSeek = false
    }

    private func resolvedValue(from event: NSEvent) -> Double {
        let point = convert(event.locationInWindow, from: nil)
        let width = max(bounds.width, 1)
        let ratio = min(max(point.x / width, 0), 1)
        let resolved = range.lowerBound + (range.upperBound - range.lowerBound) * Double(ratio)
        return min(max(resolved, range.lowerBound), range.upperBound)
    }
}

private struct NormalPlayerLayoutView: View {
    let density: DensityMetrics
    let sectionTransition: AnyTransition
    let showPlaylist: Bool
    let showInspector: Bool
    let inlineErrorView: AnyView?
    let playlistView: AnyView
    let inspectorView: AnyView
    let transportView: AnyView

    var body: some View {
        VStack(spacing: density.sectionSpacing) {
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
    let number: Int
    let title: String
    let duration: String?
    let isPlayable: Bool
    let isSelected: Bool
    let isNowPlayingTrack: Bool
    let isDragging: Bool
    let density: DensityMetrics

    var body: some View {
        HStack(spacing: density.playlistRowSpacing) {
            Text("\(number)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(isSelected ? Color.white.opacity(0.9) : .secondary)
                .frame(width: 28, alignment: .trailing)

            Text(title)
                .lineLimit(1)
                .foregroundStyle(titleColor)

            Spacer(minLength: density.playlistRowSpacing / 2)

            if let duration {
                Text(duration)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(secondaryColor)
            }

            if isNowPlayingTrack {
                NowPlayingIndicatorView(color: isSelected ? .white : .accentColor)
                    .accessibilityHidden(true)
            } else {
                Color.clear
                    .frame(width: 14, height: 12)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, density.playlistRowVerticalPadding)
        .frame(minHeight: density.playlistRowHeight, alignment: .center)
        .background(
            RoundedRectangle(cornerRadius: density.cardCornerRadius, style: .continuous)
                .fill(rowBackgroundColor)
        )
        .shadow(color: isDragging ? Color.black.opacity(0.22) : .clear, radius: isDragging ? 9 : 0, x: 0, y: isDragging ? 4 : 0)
        .scaleEffect(isDragging ? 1.008 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(duration ?? "Unknown length")
    }

    private var rowBackgroundColor: Color {
        if isSelected {
            return .accentColor
        }
        if isNowPlayingTrack {
            return Color.black.opacity(0.08)
        }
        return .clear
    }

    private var titleColor: Color {
        if isSelected {
            return .white
        }
        return isPlayable ? .primary : .secondary
    }

    private var secondaryColor: Color {
        isSelected ? Color.white.opacity(0.85) : .secondary
    }
}

private struct NowPlayingIndicatorView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let color: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { context in
            let time = context.date.timeIntervalSinceReferenceDate

            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<3, id: \.self) { index in
                    Capsule(style: .continuous)
                        .fill(color)
                        .frame(width: 3, height: barHeight(at: index, time: time))
                }
            }
            .frame(width: 14, height: 12, alignment: .bottom)
        }
    }

    private func barHeight(at index: Int, time: TimeInterval) -> CGFloat {
        if reduceMotion {
            return [6.0, 11.0, 8.0][index]
        }

        let oscillation = 0.45 + 0.55 * abs(sin(time * 5.4 + Double(index) * 1.2))
        return 4 + CGFloat(oscillation) * 8
    }
}

private struct PlaylistInsertionIndicatorView: View {
    var body: some View {
        Capsule(style: .continuous)
            .fill(Color.accentColor.opacity(0.9))
            .frame(height: 3)
            .padding(.leading, 46)
            .padding(.trailing, 10)
            .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .center)))
            .accessibilityHidden(true)
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
