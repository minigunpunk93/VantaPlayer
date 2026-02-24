import SwiftUI

extension View {
    func vantaCard(
        cornerRadius: CGFloat,
        borderColor: Color = Color.white.opacity(0.08)
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        return self
            .background(.regularMaterial, in: shape)
            .overlay(shape.strokeBorder(borderColor, lineWidth: 1))
            .clipShape(shape)
    }
}
