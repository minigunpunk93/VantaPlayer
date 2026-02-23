import SwiftUI

struct QueuePickerView: View {
    let tracks: [Track]
    let selectedTrackID: Track.ID?
    let densityMode: DensityMode
    let onSelectTrack: (Track.ID) -> Void

    var body: some View {
        Menu {
            if tracks.isEmpty {
                Text("No tracks in queue")
            } else {
                ForEach(tracks) { track in
                    Button {
                        onSelectTrack(track.id)
                    } label: {
                        if track.id == selectedTrackID {
                            Label(track.title, systemImage: "checkmark")
                        } else {
                            Text(track.title)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(currentTitle)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 6)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, densityMode.queueHorizontalPadding)
            .padding(.vertical, densityMode.queueVerticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: densityMode.cardCornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: densityMode.cardCornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .controlSize(densityMode.controlSize)
        .disabled(tracks.isEmpty)
        .help("Queue picker")
        .accessibilityLabel("Queue")
        .accessibilityValue(currentTitle)
        .accessibilityHint("Choose a track from the queue")
    }

    private var currentTitle: String {
        guard let selectedTrackID,
              let selectedTrack = tracks.first(where: { $0.id == selectedTrackID }) else {
            return "Queue"
        }
        return selectedTrack.title
    }
}
