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

    var controlSize: ControlSize {
        switch self {
        case .compact:
            return .small
        case .comfortable:
            return .regular
        }
    }

    var contentPadding: CGFloat {
        switch self {
        case .compact:
            return 10
        case .comfortable:
            return 14
        }
    }

    var sectionSpacing: CGFloat {
        switch self {
        case .compact:
            return 8
        case .comfortable:
            return 12
        }
    }

    var cardCornerRadius: CGFloat { 12 }

    var headerSpacing: CGFloat {
        switch self {
        case .compact:
            return 10
        case .comfortable:
            return 12
        }
    }

    var headerHorizontalPadding: CGFloat {
        switch self {
        case .compact:
            return 10
        case .comfortable:
            return 12
        }
    }

    var headerVerticalPadding: CGFloat {
        switch self {
        case .compact:
            return 8
        case .comfortable:
            return 10
        }
    }

    var playlistRowSpacing: CGFloat {
        switch self {
        case .compact:
            return 10
        case .comfortable:
            return 12
        }
    }

    var playlistRowVerticalPadding: CGFloat {
        switch self {
        case .compact:
            return 1
        case .comfortable:
            return 3
        }
    }

    var playlistRowHeight: CGFloat {
        switch self {
        case .compact:
            return 32
        case .comfortable:
            return 40
        }
    }

    var transportSpacing: CGFloat {
        switch self {
        case .compact:
            return 8
        case .comfortable:
            return 10
        }
    }

    var transportHorizontalPadding: CGFloat {
        switch self {
        case .compact:
            return 10
        case .comfortable:
            return 12
        }
    }

    var transportVerticalPadding: CGFloat {
        switch self {
        case .compact:
            return 8
        case .comfortable:
            return 10
        }
    }

    var transportTimeWidth: CGFloat {
        switch self {
        case .compact:
            return 42
        case .comfortable:
            return 46
        }
    }

    var volumeSliderWidth: CGFloat {
        switch self {
        case .compact:
            return 96
        case .comfortable:
            return 108
        }
    }

    var queueHorizontalPadding: CGFloat {
        switch self {
        case .compact:
            return 10
        case .comfortable:
            return 12
        }
    }

    var queueVerticalPadding: CGFloat {
        switch self {
        case .compact:
            return 7
        case .comfortable:
            return 9
        }
    }

    var compactPlaylistMaxHeight: CGFloat {
        switch self {
        case .compact:
            return 210
        case .comfortable:
            return 240
        }
    }
}
