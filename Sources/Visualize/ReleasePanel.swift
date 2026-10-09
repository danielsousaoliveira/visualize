import SwiftUI

struct ReleasePanel: View {
    @Environment(AppState.self) private var appState
    @State private var settings: ReleaseSettings
    @State private var confirmation = ""
    let project: Project
    let operation: ReleaseOperation

    init(project: Project, operation: ReleaseOperation) {
        self.project = project
        self.operation = operation
        _settings = State(initialValue: project.releaseSettings ?? ReleaseSettings())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Push to production").font(.title2.bold())
            Text("Review the remote branches before releasing. Working files stay in place.")
                .foregroundStyle(.secondary)
            HStack {
                TextField("Main (auto: main or master)", text: $settings.main)
                TextField("Production (auto: production or prod)", text: $settings.production)
                TextField("Remote", text: $settings.remote)
            }.disabled(operation.busy)
                .onChange(of: settings) { _, _ in
                    if operation.preflight?.settings != settings { operation.preflight = nil }
                    confirmation = ""
                }
            HStack {
                Button("Fetch and review") {
                    appState.saveReleaseSettings(settings, projectID: project.id)
                    confirmation = ""
                    Task {
                        await operation.prepare(settings)
                        if let reviewed = operation.preflight {
                            settings = reviewed.settings
                            appState.saveReleaseSettings(settings, projectID: project.id)
                            operation.preflight = reviewed
                        }
                    }
                }.help("Fetch and review").disabled(operation.busy)
                if operation.busy { ProgressView().controlSize(.small) }
            }
            if let reviewed = operation.preflight {
                if reviewed.productionSHA == nil {
                    Text("The remote production branch is missing. Create \(reviewed.settings.production) from \(reviewed.settings.main)?")
                }
                Text("Main has \(reviewed.incoming.count) \(reviewed.incoming.count == 1 ? "commit" : "commits") production lacks")
                commitList(reviewed.incoming)
                Text("Production has \(reviewed.outgoing.count) \(reviewed.outgoing.count == 1 ? "commit" : "commits") main lacks")
                commitList(reviewed.outgoing)
                if reviewed.requiresConfirmation {
                    Text(reviewed.productionSHA == nil ? "Type \(reviewed.settings.production) to confirm creation." : "These production commits will be replaced. Type \(reviewed.settings.production) to confirm.")
                    TextField("Production branch name", text: $confirmation)
                }
                HStack {
                    Button("Cancel review") { operation.preflight = nil; confirmation = "" }.help("Cancel review")
                    Button(reviewed.productionSHA == nil ? "Create production branch" : "Push to production") {
                        Task { await operation.push(confirmation: confirmation) }
                    }.help("Push the reviewed commit to the production branch").disabled(operation.busy || reviewed.unchanged || (reviewed.requiresConfirmation && confirmation != reviewed.settings.production))
                }
            }
            if let result = operation.result { Text(result).textSelection(.enabled) }
            DisclosureGroup("Git command output (saved to project log)") {
                ScrollView {
                    Text(operation.output).font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 220)
            }
        }.padding(24).frame(width: 760)
    }

    private func commitList(_ commits: [String]) -> some View {
        ScrollView {
            VStack(alignment: .leading) {
                ForEach(Array(commits.enumerated()), id: \.offset) { _, commit in
                    Text(commit).font(.callout.monospaced()).textSelection(.enabled)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxHeight: commits.isEmpty ? 0 : 140)
    }
}
