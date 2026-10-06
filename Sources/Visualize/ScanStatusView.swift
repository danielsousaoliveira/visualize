import SwiftUI

struct ScanStatusView: View {
    let status: ScanStatus

    var body: some View {
        switch status {
        case .idle:
            ContentUnavailableView("No project selected", systemImage: "square.dashed")
        case .scanning(let folder):
            ProgressView("Scanning \(folder.lastPathComponent)…")
        case .finished(let summary):
            report(summary, style: .primary)
        case .failed(let message):
            report(message, style: .red)
        }
    }

    private func report(_ text: String, style: Color) -> some View {
        ScrollView {
            Text(text)
                .font(.body.monospaced())
                .foregroundStyle(style)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
    }
}
