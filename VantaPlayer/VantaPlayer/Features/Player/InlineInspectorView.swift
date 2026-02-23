import SwiftUI

struct InlineInspectorView: View {
    let currentTrack: Track?
    let trackCount: Int
    let revealInFinder: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Inspector")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
            }

            if let currentTrack {
                InspectorRow(label: "Filename", value: currentTrack.url.lastPathComponent)

                InspectorRow(
                    label: "Duration",
                    value: durationText(currentTrack.duration)
                )

                InspectorRow(label: "File URL", value: currentTrack.url.path)

                Button("Reveal in Finder") {
                    revealInFinder(currentTrack.url)
                }
                .buttonStyle(.link)
                .accessibilityLabel("Reveal selected track in Finder")
            } else {
                Text("No track selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            InspectorRow(label: "Track Count", value: "\(trackCount)")
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Inspector")
    }

    private func durationText(_ duration: TimeInterval?) -> String {
        guard let duration, duration.isFinite, duration > 0 else {
            return "Unknown"
        }

        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = duration >= 3600 ? [.hour, .minute, .second] : [.minute, .second]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = [.pad]
        return formatter.string(from: duration) ?? "Unknown"
    }
}

private struct InspectorRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text(value)
                .font(.caption)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .accessibilityElement(children: .combine)
    }
}
