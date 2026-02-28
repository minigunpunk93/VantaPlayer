import SwiftUI

enum VantaGlassDepth {
    case background
    case mid
    case foreground

    var material: AnyShapeStyle {
        switch self {
        case .background:
            return AnyShapeStyle(.ultraThinMaterial)
        case .mid:
            return AnyShapeStyle(.thinMaterial)
        case .foreground:
            return AnyShapeStyle(.regularMaterial)
        }
    }

    var tint: Color {
        switch self {
        case .background:
            return Color.white.opacity(0.06)
        case .mid:
            return Color.white.opacity(0.1)
        case .foreground:
            return Color.white.opacity(0.14)
        }
    }

    var highlightOpacity: Double {
        switch self {
        case .background:
            return 0.24
        case .mid:
            return 0.32
        case .foreground:
            return 0.38
        }
    }

    var shadowOpacity: Double {
        switch self {
        case .background:
            return 0.08
        case .mid:
            return 0.11
        case .foreground:
            return 0.14
        }
    }
}

extension View {
    func vantaCard(
        cornerRadius: CGFloat,
        borderColor: Color = Color.white.opacity(0.1),
        depth: VantaGlassDepth = .mid
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        return self
            .background(depth.material, in: shape)
            .background(shape.fill(depth.tint))
            .overlay(shape.strokeBorder(borderColor, lineWidth: 1))
            .overlay(
                shape
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(depth.highlightOpacity),
                                Color.white.opacity(0.02)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: Color.black.opacity(depth.shadowOpacity), radius: 14, x: 0, y: 8)
            .clipShape(shape)
    }
}
