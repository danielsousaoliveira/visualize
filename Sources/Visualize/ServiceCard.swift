import SwiftUI

struct ServiceCard: View {
    @Environment(AppState.self) private var appState

    let project: Project
    @State private var pendingRecipe: RunRecipe?
    @State private var showConfirmation = false
    @State private var confirmingRestart = false

    let service: ScanService
    let environment: ScanEnvRequirement?

    private var variables: [ScanEnvVariable] { environment?.variables ?? [] }
    private var missing: [ScanEnvVariable] { variables.filter { $0.status == .missing } }
    private var setCount: Int { variables.filter { $0.status != .missing }.count }
    private var listeners: [ProcessListener] {
        appState.listenerStore.listeners.filter { $0.libraryProjectID == project.id && $0.serviceID == service.id }
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(service.name).font(.headline)
                    Spacer()
                    if let run = appState.serviceRuns[appState.runKey(project: project, service: service)], run.active || run.docker != nil {
                        if run.active {
                            Button("Stop", systemImage: "stop.fill") {
                                Task { await appState.stop(project: project, service: service) }
                            }.help("Stop").disabled(run.stopping || run.busy || (run.pid == nil && run.docker == nil))
                        }
                        Button("Restart", systemImage: "arrow.clockwise") {
                            Task { await appState.restart(project: project, service: service) }
                        }.help("Restart").disabled(run.stopping || run.busy || (run.pid == nil && run.docker == nil) || (run.docker != nil && appState.dockerReason(project: project, service: service) != nil))
                    }
                    ServicePlayButton(project: project, service: service)
                    Text(service.rootDirectory).font(.callout.monospaced()).foregroundStyle(.secondary)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 20) { metadata }
                    VStack(alignment: .leading, spacing: 6) { metadata }
                }
                let run = appState.serviceRuns[appState.runKey(project: project, service: service)]
                HStack {
                    Text(run?.active == true ? run?.status ?? "Running" : listeners.isEmpty ? run?.status ?? "Stopped" : "Running externally")
                    if let port = service.port, listeners.isEmpty {
                        Label(run?.docker != nil && run?.active == true ? "Port \(port) published" : run?.portReady == true ? "Port \(port) listening" : "Port \(port) waiting", systemImage: run?.portReady == true ? "circle.fill" : "circle")
                            .foregroundStyle(run?.portReady == true ? .green : .secondary)
                    }
                }.font(.callout)
                if let reason = appState.dockerReason(project: project, service: service) {
                    Text(reason).font(.callout).foregroundStyle(.secondary)
                }
                if let run, run.status.hasPrefix("Failed:") {
                    Text(run.lastOutputLines).font(.callout.monospaced()).textSelection(.enabled)
                }
                if let run, run.docker == nil, let current = appState.recipe(project: project, service: service),
                   current.approvalKey != run.recipe.approvalKey {
                    Text("The dev command has changed. Restart uses the command recorded at launch.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Restart with new command") {
                        pendingRecipe = current
                        confirmingRestart = true
                        showConfirmation = true
                    }.help("Restart with new command").disabled(run.stopping || run.busy || (run.pid == nil && run.docker == nil))
                }
                if let command = service.devCommand {
                    ScrollView(.horizontal) {
                        Text(command.argv.map(shellArgument).joined(separator: " "))
                            .font(.callout.monospaced())
                            .fixedSize()
                            .textSelection(.enabled)
                    }
                    .help("Run in \(command.workingDirectory) • \(command.source)")
                    .accessibilityLabel("Dev command")
                } else {
                    Text("No dev command detected").font(.callout).foregroundStyle(.secondary)
                }
                Picker("Run mode", selection: Binding(
                    get: { appState.mode(project: project, service: service) },
                    set: { appState.setMode($0, project: project, service: service) }
                )) {
                    ForEach(ServiceMode.available(for: service)) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .help("Choose how to run this service")
                .disabled(run?.active == true || run?.busy == true || run?.stopping == true)
                if !listeners.isEmpty {
                    Divider()
                    RunningListenersView(listeners: listeners)
                }
                if environment == nil {
                    Text("Env status unavailable — rescan to check").font(.callout).foregroundStyle(.secondary)
                } else if missing.isEmpty {
                    Text("\(setCount) set, 0 missing").font(.callout).foregroundStyle(.secondary)
                } else {
                    DisclosureGroup("\(setCount) set, \(missing.count) missing") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(missing, id: \.name) { variable in
                                Text(variable.name).font(.callout.monospaced()).textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                    }
                    .font(.callout)
                    .help("Show missing environment variable names")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
        .disabled(appState.projectOperations[project.id]?.busy == true)
        .sheet(isPresented: $showConfirmation) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Run this command?").font(.title2)
                Text(pendingRecipe?.displayCommand ?? "").font(.body.monospaced()).textSelection(.enabled)
                Text(pendingRecipe?.workingDirectory ?? "").font(.callout.monospaced()).textSelection(.enabled)
                HStack {
                    Spacer()
                    Button("Cancel") { showConfirmation = false }.help("Cancel").keyboardShortcut(.cancelAction)
                    Button("Run") {
                        if let recipe = pendingRecipe {
                            Task {
                                if confirmingRestart {
                                    await appState.restart(project: project, service: service, recipe: recipe)
                                } else {
                                    await appState.start(project: project, service: service, recipe: recipe)
                                }
                            }
                        }
                        showConfirmation = false
                    }.help("Run").keyboardShortcut(.defaultAction)
                }
            }.padding(24).frame(minWidth: 480)
        }
    }

    @ViewBuilder
    private var metadata: some View {
        if let stack = service.stackId { Text([stack, service.category].compactMap { $0 }.joined(separator: " • ")) }
        else if let image = composeImage { Text("Image: \(image)") }
        else { Text(service.runModes.compose.available ? "Compose service" : "Application stack not detected") }
        if let manager = service.packageManager { Text("Package manager: \(manager)") }
        Text(service.port.map { "Port: \(String($0))" } ?? "Port: Not detected")
    }

    private var composeImage: String? {
        project.lastResult?.composeServices.first {
            $0.name == service.runModes.compose.serviceName && $0.composeFile == service.runModes.compose.composeFile
        }?.image
    }

    private func shellArgument(_ argument: String) -> String {
        if !argument.isEmpty && argument.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_./:@%+=,-".contains($0)) }) {
            return argument
        }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
