import SwiftUI

struct ProjectOperationView: View {
    @Environment(AppState.self) private var appState
    let project: Project
    let operation: ProjectOperation

    private var issues: [String] {
        operation.order.filter {
            let status = operation.statuses[$0] ?? ""
            return status.hasPrefix("failed") || status.hasPrefix("blocked") || status.hasPrefix("unavailable")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if operation.busy {
                    ProgressView().controlSize(.small)
                    Text(operation.action).font(.callout.weight(.medium))
                } else {
                    Label(issues.isEmpty ? operation.completion : "Some services need attention",
                          systemImage: issues.isEmpty ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(issues.isEmpty ? Color.secondary : Color.orange)
                    Spacer()
                    Button("Dismiss", systemImage: "xmark") { appState.projectOperations[project.id] = nil }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Dismiss the operation summary")
                }
            }
            if operation.busy || !issues.isEmpty {
                ForEach(operation.busy ? operation.order : issues, id: \.self) { id in
                    HStack {
                        Text(project.lastResult?.services.first { $0.id == id }?.name ?? appState.launchedServices[project.id]?[id]?.name ?? id)
                        Spacer()
                        Text(operation.statuses[id] ?? "waiting").foregroundStyle(.secondary)
                    }.font(.callout)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}
