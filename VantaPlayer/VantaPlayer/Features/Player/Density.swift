import SwiftUI

enum DensityMode: String, CaseIterable, Identifiable {
    case compact
    case comfortable

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compact:
            return "Compact"
        case .comfortable:
            return "Comfortable"
        }
    }

    var metrics: DensityMetrics {
        switch self {
        case .compact:
            return DensityMetrics(
                controlSize: .small,
                queueControlSize: .small,
                contentPadding: 10,
                sectionSpacing: 8,
                cardCornerRadius: 12,
                headerInnerSpacing: 10,
                headerSubtitleSpacing: 2,
                headerHorizontalPadding: 10,
                headerVerticalPadding: 8,
                inspectorSpacing: 8,
                inspectorRowSpacing: 2,
                inspectorPadding: 10,
                playlistRowSpacing: 10,
                playlistRowVerticalPadding: 1,
                playlistRowHeight: 38,
                transportSpacing: 8,
                transportHorizontalPadding: 10,
                transportVerticalPadding: 8,
                transportTimeWidth: 42,
                volumeSliderWidth: 96,
                queueHorizontalPadding: 10,
                queueVerticalPadding: 7,
                compactPlaylistMaxHeight: 210
            )
        case .comfortable:
            return DensityMetrics(
                controlSize: .regular,
                queueControlSize: .small,
                contentPadding: 13,
                sectionSpacing: 11,
                cardCornerRadius: 12,
                headerInnerSpacing: 12,
                headerSubtitleSpacing: 3,
                headerHorizontalPadding: 11,
                headerVerticalPadding: 9,
                inspectorSpacing: 10,
                inspectorRowSpacing: 2,
                inspectorPadding: 12,
                playlistRowSpacing: 12,
                playlistRowVerticalPadding: 3,
                playlistRowHeight: 44,
                transportSpacing: 10,
                transportHorizontalPadding: 11,
                transportVerticalPadding: 9,
                transportTimeWidth: 46,
                volumeSliderWidth: 108,
                queueHorizontalPadding: 12,
                queueVerticalPadding: 9,
                compactPlaylistMaxHeight: 240
            )
        }
    }
}

struct DensityMetrics {
    let controlSize: ControlSize
    let queueControlSize: ControlSize
    let contentPadding: CGFloat
    let sectionSpacing: CGFloat
    let cardCornerRadius: CGFloat

    let headerInnerSpacing: CGFloat
    let headerSubtitleSpacing: CGFloat
    let headerHorizontalPadding: CGFloat
    let headerVerticalPadding: CGFloat

    let inspectorSpacing: CGFloat
    let inspectorRowSpacing: CGFloat
    let inspectorPadding: CGFloat

    let playlistRowSpacing: CGFloat
    let playlistRowVerticalPadding: CGFloat
    let playlistRowHeight: CGFloat

    let transportSpacing: CGFloat
    let transportHorizontalPadding: CGFloat
    let transportVerticalPadding: CGFloat
    let transportTimeWidth: CGFloat
    let volumeSliderWidth: CGFloat

    let queueHorizontalPadding: CGFloat
    let queueVerticalPadding: CGFloat

    let compactPlaylistMaxHeight: CGFloat
}
