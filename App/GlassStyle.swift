import SwiftUI

/// Soft gradient backdrop so Liquid Glass chrome has color to refract.
/// iOS 26+ deployment target (AD-9): glass APIs apply unconditionally.
struct GlassBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color.orange.opacity(0.18),
                Color.teal.opacity(0.12),
                Color(.systemBackground),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}

/// Capsule filter chip; tinted glass when selected, interactive for touch.
struct GlassChipLabel: View {
    let title: String
    let systemImage: String
    var selected: Bool = false

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.medium))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .glassEffect(
                .regular.tint(selected ? Color.orange.opacity(0.45) : .clear).interactive(),
                in: .capsule
            )
    }
}