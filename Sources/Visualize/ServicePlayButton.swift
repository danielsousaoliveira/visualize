import SwiftUI

struct ServicePlayButton: View {
    @Environment(AppState.self) private var appState
    let project: Project
    let service: ScanService
    var iconOnly = false
    @State private var confirmation: ServiceStartConfirmation?

    private var run: ServiceRun? { appState.serviceRuns[appState.runKey(project: project, service: service)] }

    var body: some View {
        Button(action: requestStart) {
            if iconOnly { Image(systemName: "play.fill") }
            else { Label("Play", systemImage: "play.fill") }
        }
        .accessibilityLabel("Play \(service.name)")
        .help(appState.dockerReason(project: project, service: service) ?? appState.mode(project: project, service: service).rawValue)
        .disabled(ServiceMode.available(for: service).isEmpty || appState.dockerReason(project: project, service: service) != nil || run?.active == true || run?.busy == true || run?.stopping == true || appState.projectOperations[project.id]?.busy == true)
        .sheet(item: $confirmation) { request in
            VStack(alignment: .leading, spacing: 16) {
                Text(request.mode == .local ? "Run this command?" : "Run this Docker service?").font(.title2)
                if let recipe = request.recipe {
                    Text(recipe.displayCommand).font(.body.monospaced()).textSelection(.enabled)
                    Text(recipe.workingDirectory).font(.callout.monospaced()).textSelection(.enabled)
                } else if request.mode == .compose {
                    Text("Start compose service \(service.runModes.compose.serviceName ?? service.name) from \(service.runModes.compose.composeFile ?? "") and its dependencies.")
                    Text("Compose may build images and execute commands defined by this project.")
                } else {
                    Text("Build \(service.runModes.dockerfile.dockerfilePath ?? "Dockerfile") with context \(service.rootDirectory), then run its image.")
                    Text("The Dockerfile and image may execute commands defined by this project.")
                }
                HStack {
                    Spacer()
                    Button("Cancel") { confirmation = nil }.help("Cancel").keyboardShortcut(.cancelAction)
                    Button("Run") {
                        let mode = request.mode
                        let recipe = request.recipe
                        Task {
                            if mode == .local, let recipe {
                                await appState.start(project: project, service: service, recipe: recipe)
                            } else {
                                await appState.startDocker(project: project, service: service, selectedMode: mode)
                            }
                        }
                        confirmation = nil
                    }.help("Run").keyboardShortcut(.defaultAction)
                }
            }.padding(24).frame(minWidth: 480)
        }
    }

    private func requestStart() {
        let mode = appState.mode(project: project, service: service)
        var pendingRecipe: RunRecipe?
        if mode == .local {
            guard let recipe = appState.recipe(project: project, service: service) else { return }
            if appState.approved(recipe, project: project) {
                Task { await appState.start(project: project, service: service, recipe: recipe) }
                return
            }
            pendingRecipe = recipe
        }
        confirmation = ServiceStartConfirmation(mode: mode, recipe: pendingRecipe)
    }
}
