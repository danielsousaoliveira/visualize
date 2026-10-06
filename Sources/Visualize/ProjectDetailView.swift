import SwiftUI

struct ProjectDetailView: View {
    let project: Project
    let isScanning: Bool
    let error: String?
    let onLocate: () -> Void
    let onRemove: () -> Void

    var body: some View {
        if project.folderExists {
            VStack(spacing: 0) {
                if let error {
                    errorBanner(error)
                    Divider()
                }
                content
            }
        } else {
            ContentUnavailableView {
                Label("Folder missing", systemImage: "questionmark.folder")
            } description: {
                Text("\(project.folderPath) no longer exists. It may have been moved or renamed.")
            } actions: {
                Button("Locate…", action: onLocate)
                Button("Remove", role: .destructive, action: onRemove)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let result = project.lastResult {
            ScrollView {
                Text(result.summary)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        } else if isScanning {
            ProgressView("Scanning \(project.name)…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if error == nil {
            ContentUnavailableView("Not scanned yet", systemImage: "magnifyingglass")
        } else {
            Spacer()
        }
    }

    private func errorBanner(_ message: String) -> some View {
        Label {
            Text(message)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .foregroundStyle(.red)
        .padding()
        .background(.red.opacity(0.08))
    }
}
