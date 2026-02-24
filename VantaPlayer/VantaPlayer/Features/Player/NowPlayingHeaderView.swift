import SwiftUI

struct NowPlayingHeaderView: View {
    let currentTrack: Track?
    let isPlaying: Bool
    let playbackDuration: TimeInterval
    let isImporting: Bool
    let densityMode: DensityMode

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

    var body: some View {
        let density = densityMode.metrics

        HStack(alignment: .center, spacing: density.headerInnerSpacing) {
            VStack(alignment: .leading, spacing: density.headerSubtitleSpacing) {
                Text(primaryTitle)
                    .font(.headline)
                    .lineLimit(1)

                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Text(statusText)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.thinMaterial, in: Capsule())
        }
        .padding(.horizontal, density.headerHorizontalPadding)
        .padding(.vertical, density.headerVerticalPadding)
        .vantaCard(cornerRadius: density.cardCornerRadius)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var primaryTitle: String {
        currentTrack?.title ?? "No Track Selected"
    }

    private var subtitle: String? {
        guard let currentTrack else { return nil }

        var parts: [String] = []
        if let artist = currentTrack.artist, !artist.isEmpty {
            parts.append(artist)
        }
        if let album = currentTrack.album, !album.isEmpty {
            parts.append(album)
        }

        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }

    private var statusText: String {
        if isImporting {
            return "Importing"
        }

        guard currentTrack != nil else {
            return "Idle"
        }

        let base = isPlaying ? "Playing" : "Paused"
        let resolvedDuration = currentTrack?.duration ?? (playbackDuration > 0 ? playbackDuration : nil)
        guard let resolvedDuration else {
            return base
        }

        return "\(base) · \(timeString(resolvedDuration))"
    }

    private var accessibilityLabel: String {
        if let subtitle {
            return "\(primaryTitle), \(subtitle), \(statusText)"
        }
        return "\(primaryTitle), \(statusText)"
    }

    private func timeString(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }

        if seconds >= 3600 {
            return Self.hourFormatter.string(from: seconds) ?? "0:00"
        }

        return Self.minuteFormatter.string(from: seconds) ?? "0:00"
    }
}
