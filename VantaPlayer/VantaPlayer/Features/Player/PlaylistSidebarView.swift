import SwiftUI

struct PlaylistSidebarView: View {
    let tracks: [Track]
    @Binding var selection: Track.ID?
    let onSelect: (Track.ID) -> Void
    let onMove: (IndexSet, Int) -> Void

    var body: some View {
        List(selection: $selection) {
            ForEach(tracks) { track in
                playlistRow(track)
                    .tag(track.id)
                    .contentShape(Rectangle())
                    .accessibilityLabel(track.title)
                    .accessibilityHint(track.isPlayable ? "Play this track" : "Track cannot be played")
            }
            .onMove(perform: onMove)
        }
        .listStyle(.sidebar)
        .navigationTitle("Playlist")
        .overlay {
            if tracks.isEmpty {
                ContentUnavailableView(
                    "No Tracks Yet",
                    systemImage: "music.note.list",
                    description: Text("Drop audio files into the window or press ⌘O.")
                )
                .padding(.horizontal, 14)
            }
        }
        .onChange(of: selection) { _, newValue in
            guard let newValue else { return }
            onSelect(newValue)
        }
        .accessibilityElement(children: .contain)
        .accessibilitySortPriority(3)
    }

    @ViewBuilder
    private func playlistRow(_ track: Track) -> some View {
        HStack(spacing: 10) {
            Image(systemName: track.isPlayable ? "waveform" : "exclamationmark.triangle.fill")
                .foregroundStyle(track.isPlayable ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .lineLimit(1)
                Text(durationString(track.duration))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func durationString(_ duration: TimeInterval?) -> String {
        guard let duration, duration.isFinite, duration > 0 else {
            return "Unknown length"
        }

        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = duration >= 3600 ? [.hour, .minute, .second] : [.minute, .second]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = [.pad]

        return formatter.string(from: duration) ?? "Unknown length"
    }
}
