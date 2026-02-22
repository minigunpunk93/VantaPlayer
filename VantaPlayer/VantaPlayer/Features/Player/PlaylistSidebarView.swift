import SwiftUI

struct PlaylistSidebarView: View {
    let tracks: [Track]
    @Binding var selection: Track.ID?
    let isImporting: Bool
    let importProgressLabel: String?
    let onSelect: (Track.ID) -> Void
    let onMove: (IndexSet, Int) -> Void
    let onRemove: (Track.ID) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if isImporting {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(importProgressLabel ?? "Importing…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(importProgressLabel ?? "Importing")
            }

            List(selection: $selection) {
                ForEach(tracks) { track in
                    playlistRow(track)
                        .tag(track.id)
                        .contentShape(Rectangle())
                        .contextMenu {
                            Button("Remove") {
                                onRemove(track.id)
                            }
                        }
                        .accessibilityLabel(track.title)
                        .accessibilityHint(track.isPlayable ? "Play this track" : "Track cannot be played")
                }
                .onMove(perform: onMove)
            }
            .listStyle(.sidebar)
        }
        .navigationTitle("Playlist")
        .overlay {
            if tracks.isEmpty {
                ContentUnavailableView(
                    "No Tracks Yet",
                    systemImage: "music.note.list",
                    description: Text("Drop audio files into the window, press ⌘O, or use ⌘⇧O for folders.")
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

                if let subtitle = track.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text(durationString(track.duration))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 6)

            if let duration = track.duration, duration > 0 {
                Text(durationString(duration))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
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
