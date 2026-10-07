import SwiftUI

struct RunModeChip: View {
    let title: String
    let available: Bool
    let reason: String?

    var body: some View {
        Label(title, systemImage: available ? "checkmark" : "minus")
            .font(.caption.weight(.medium))
            .foregroundStyle(available ? Color.primary : Color.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(available ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08), in: Capsule())
            .help(available ? "\(title) available" : reason ?? "\(title) unavailable")
            .accessibilityLabel("\(title): \(available ? "available" : reason ?? "unavailable")")
    }
}
