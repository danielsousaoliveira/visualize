import SwiftUI

struct ProjectDetailView: View {
    @Environment(AppState.self) private var appState
    @State private var showRelease = false
    @State private var explainRelease = false
    @State private var showDatabaseConnections = false
    @State private var graphSelected = false
    @State private var logServiceID: String?
    @State private var startMode: ProjectStartMode = .configured
    @State private var pendingStartMode: ProjectStartMode?
    @State private var pendingCommands: [RunRecipe] = []
    @State private var showStartConfirmation = false
    let project: Project
    let isScanning: Bool
    let error: String?
    let onRescan: () -> Void
    let onLocate: () -> Void
    let onRemove: () -> Void

    var body: some View {
        Group {
            if project.folderExists {
                VStack(spacing: 0) {
                    content
                    if let error {
                        Divider()
                        errorBanner(error)
                    }
                }
            } else {
                ContentUnavailableView {
                    Label("Folder missing", systemImage: "questionmark.folder")
                } description: {
                    Text("\(project.folderPath) no longer exists. It may have been moved or renamed.")
                } actions: {
                    Button("Locate…", action: onLocate).help("Locate…")
                    Button("Remove", role: .destructive, action: onRemove).help("Remove")
                }
            }
        }
        .toolbar {
            Button("Connect", systemImage: "externaldrive") { showDatabaseConnections = true }.help("Manage database connections")
                .disabled(!project.folderExists)
            Button("Push to production", systemImage: "arrow.up.circle") { explainRelease = true }.help("Review a production release")
                .disabled(!project.folderExists)
        }
        .alert("Review a production release?", isPresented: $explainRelease) {
            Button("Continue to review") { showRelease = true }.help("Open the release review")
            Button("Cancel", role: .cancel) {}.help("Cancel the release review")
        } message: {
            Text("This opens the release review for \(project.name). Fetch and review will contact the selected Git remote and compare main or master with production or prod. You can change those branches and the remote before fetching. After review, a separate confirmation will push the reviewed main commit to the production branch. Production-only commits may be replaced if you explicitly confirm. Working files stay in place. Any deployment triggered by that remote branch may run after the push.")
        }
        .sheet(isPresented: $showDatabaseConnections) {
            DatabaseConnectionsView(project: project)
        }
        .sheet(isPresented: $showRelease) {
            VStack(alignment: .trailing) {
                ScrollView {
                    ReleasePanel(project: project, operation: appState.releaseOperation(project: project))
                }.frame(maxHeight: 640)
                Button("Close") { showRelease = false }.help("Close")
                    .keyboardShortcut(.cancelAction)
                    .padding([.trailing, .bottom], 24)
            }
        }
        .sheet(isPresented: $showStartConfirmation) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Run these commands?").font(.title2)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(pendingCommands.enumerated()), id: \.offset) { _, recipe in
                            Text(recipe.displayCommand).font(.body.monospaced()).textSelection(.enabled)
                            Text(recipe.workingDirectory).font(.callout.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }.frame(maxHeight: 320)
                HStack {
                    Spacer()
                    Button("Cancel") { showStartConfirmation = false }.help("Cancel").keyboardShortcut(.cancelAction)
                    Button("Start all") {
                        if let mode = pendingStartMode { Task { await appState.startAll(project: project, mode: mode) } }
                        showStartConfirmation = false
                    }.help("Start all").keyboardShortcut(.defaultAction)
                }
            }.padding(24).frame(minWidth: 480)
        }
    }

    private func requestStart(_ mode: ProjectStartMode) {
        pendingCommands = (project.lastResult?.services ?? []).compactMap { service in
            guard appState.serviceRuns[appState.runKey(project: project, service: service)]?.active != true,
                  mode.resolve(service, remembered: appState.mode(project: project, service: service)) == .local,
                  let recipe = appState.recipe(project: project, service: service), !appState.approved(recipe, project: project) else { return nil }
            return recipe
        }
        if pendingCommands.isEmpty { Task { await appState.startAll(project: project, mode: mode) } }
        else {
            pendingStartMode = mode
            showStartConfirmation = true
        }
    }

    @ViewBuilder
    private var content: some View {
        if let result = project.lastResult {
            VStack(spacing: 0) {
                Picker("Project view", selection: Binding(
                    get: { graphSelected },
                    set: { graphSelected = $0; logServiceID = nil }
                )) {
                    Text("Services").tag(false)
                    Text("Graph").tag(true)
                }.pickerStyle(.segmented).padding(.horizontal, 24).padding(.top, 12)
                if graphSelected, let model = appState.graphModel(projectID: project.id) {
                    ProjectGraphView(project: project, model: model) { id in
                        logServiceID = id
                        graphSelected = false
                    }.id(project.id)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 24) {
                                header(result)
                                if let operation = appState.projectOperations[project.id], !operation.order.isEmpty {
                                    ProjectOperationView(project: project, operation: operation)
                                }
                                if !result.services.contains(where: {
                                    $0.runModes.local.available || $0.runModes.compose.available || $0.runModes.dockerfile.available
                                }) && result.composeServices.isEmpty {
                                    ContentUnavailableView("Nothing runnable detected in this folder", systemImage: "magnifyingglass")
                                }
                                let providers = Set(result.infra.compactMap(\.providedBy))
                                let services = result.services.filter { !providers.contains($0.id) }
                                if !services.isEmpty {
                                    sectionTitle("Services", count: services.count)
                                    ForEach(services) { service in
                                        ServiceCard(project: project, service: service, environment: result.envRequirements.first { $0.serviceId == service.id })
                                    }
                                }
                                if !result.infra.isEmpty {
                                    sectionTitle("Databases", count: result.infra.count)
                                    ForEach(result.infra, id: \.id) { infra in
                                        DatabaseServiceCard(project: project, infra: infra, result: result)
                                    }
                                }
                                if !result.composeFiles.isEmpty {
                                    sectionTitle("Compose", count: result.composeFiles.count)
                                    ForEach(result.composeFiles, id: \.self) { file in
                                        ComposeFileCard(file: file, result: result)
                                    }
                                }
                                let messages = result.warnings + (appState.projectOperations[project.id]?.warnings ?? [])
                                if !messages.isEmpty {
                                    DisclosureGroup("Warnings (\(messages.count))") {
                                        warnings(messages)
                                    }.help("Show or hide scan and operation warnings")
                                }
                                ServiceLogsPanel(project: project, services: result.services, requestedSelection: logServiceID)
                                    .id("service-logs")
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(24)
                        }
                        .onChange(of: logServiceID, initial: true) { _, selection in
                            if selection != nil { proxy.scrollTo("service-logs", anchor: .top) }
                        }
                    }
                }
            }
        } else if isScanning {
            ProgressView("Scanning \(project.name)…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if error == nil {
            ContentUnavailableView {
                Label("Not scanned yet", systemImage: "magnifyingglass")
            } actions: {
                Button("Rescan", action: onRescan).help("Scan this folder and its subfolders again")
            }
        } else {
            ContentUnavailableView {
                Label("Scan failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text("Rescan to try again.")
            } actions: {
                Button("Rescan", action: onRescan).help("Scan this folder and its subfolders again")
            }
        }
    }

    private func header(_ result: ScanResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(project.name).font(.title.bold()).lineLimit(1)
                Spacer()
                if isScanning { ProgressView().controlSize(.small) }
            }
            HStack {
                Picker("Start mode", selection: $startMode) {
                    Text("Configured").tag(ProjectStartMode.configured)
                    if result.services.contains(where: { ServiceMode.available(for: $0).contains(.local) }) {
                        Text("Local").tag(ProjectStartMode.local)
                    }
                    if dockerStartAvailable(result) {
                        Text("Docker").tag(ProjectStartMode.docker)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .disabled(appState.projectOperations[project.id]?.busy == true || isScanning)
                .help("Choose how to start the services; unsupported services stay stopped")
                .onChange(of: dockerStartAvailable(result)) { _, available in
                    if !available && startMode == .docker { startMode = .configured }
                }
                Button("Start all", systemImage: "play.fill") { requestStart(startMode) }
                    .disabled(appState.projectOperations[project.id]?.busy == true || isScanning || !canStart(result))
                    .help("Start stopped services using the selected mode")
                Button("Stop all") { Task { await appState.stopAll(project: project) } }
                    .disabled(appState.projectOperations[project.id]?.busy == true || !hasManagedServices)
                    .help("Stop services started by visualize")
                Button("Rescan", systemImage: "arrow.clockwise", action: onRescan).help("Scan this folder and its subfolders again")
                    .disabled(isScanning || appState.projectOperations[project.id]?.busy == true)
            }
            Text(project.folderPath)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            HStack(spacing: 20) {
                Label(result.project.gitBranch ?? "No git branch detected", systemImage: "arrow.triangle.branch")
                Text("Type: \(result.project.type.rawValue)")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            if error != nil {
                Text("Showing the last successful scan").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var hasManagedServices: Bool {
        appState.serviceRuns.contains { key, run in
            key.hasPrefix(project.id.uuidString + ":") && (run.active || run.docker != nil)
        }
    }

    private func dockerStartAvailable(_ result: ScanResult) -> Bool {
        result.services.contains { service in
            ServiceMode.available(for: service).contains { mode in
                mode != .local && appState.dockerState.unavailableReason(compose: mode == .compose) == nil
            }
        }
    }

    private func canStart(_ result: ScanResult) -> Bool {
        result.services.contains { service in
            guard appState.serviceRuns[appState.runKey(project: project, service: service)]?.active != true,
                  let mode = startMode.resolve(service, remembered: appState.mode(project: project, service: service)) else { return false }
            return mode == .local || appState.dockerState.unavailableReason(compose: mode == .compose) == nil
        }
    }

    private func sectionTitle(_ title: String, count: Int) -> some View {
        HStack {
            Text(title).font(.title2.weight(.semibold))
            Text("\(count)").font(.callout).foregroundStyle(.secondary)
        }
    }

    private func warnings(_ messages: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(messages.enumerated()), id: \.offset) { _, message in
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
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
