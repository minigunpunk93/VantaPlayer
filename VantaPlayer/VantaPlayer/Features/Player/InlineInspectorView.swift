import SwiftUI

struct InlineInspectorView: View {
    let currentTrack: Track?
    let trackCount: Int
    let densityMode: DensityMode
    let revealInFinder: (URL) -> Void

    var body: some View {
        let density = densityMode.metrics

        VStack(alignment: .leading, spacing: density.inspectorSpacing) {
            HStack {
                Text("Inspector")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
            }

            if let currentTrack {
                InspectorRow(label: "Filename", value: currentTrack.url.lastPathComponent, densityMode: densityMode)

                InspectorRow(
                    label: "Duration",
                    value: durationText(currentTrack.duration),
                    densityMode: densityMode
                )

                InspectorRow(label: "File URL", value: currentTrack.url.path, densityMode: densityMode)

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

            InspectorRow(label: "Track Count", value: "\(trackCount)", densityMode: densityMode)
        }
        .padding(density.inspectorPadding)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: density.cardCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: density.cardCornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
        .controlSize(density.controlSize)
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
    let densityMode: DensityMode

    var body: some View {
        VStack(alignment: .leading, spacing: densityMode.metrics.inspectorRowSpacing) {
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
