import SwiftUI

struct ProjectRow: View {
    let project: Project
    let isScanning: Bool

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                Text(project.folderPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if isScanning {
                ProgressView()
                    .controlSize(.small)
            } else if !project.folderExists {
                Text("Folder missing")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.orange.opacity(0.15), in: Capsule())
            }
        }
        .padding(.vertical, 2)
    }
}
