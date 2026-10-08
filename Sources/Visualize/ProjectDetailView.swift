import SwiftUI

struct ProjectDetailView: View {
    @Environment(AppState.self) private var appState
    @State private var showRelease = false
    @State private var graphSelected = false
    @State private var logServiceID: String?
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
        .toolbar {
            Button("Push to production", systemImage: "arrow.up.circle") { showRelease = true }
                .disabled(!project.folderExists)
        }
        .sheet(isPresented: $showRelease) {
            VStack(alignment: .trailing) {
                ScrollView {
                    ReleasePanel(project: project, operation: appState.releaseOperation(project: project))
                }.frame(maxHeight: 640)
                Button("Close") { showRelease = false }
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
                    Button("Cancel") { showStartConfirmation = false }.keyboardShortcut(.cancelAction)
                    Button("Start all") {
                        if let mode = pendingStartMode { Task { await appState.startAll(project: project, mode: mode) } }
                        showStartConfirmation = false
                    }.keyboardShortcut(.defaultAction)
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
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 24) {
                            header(result)
                            if let operation = appState.projectOperations[project.id] {
                                GroupBox("Project progress") {
                                    VStack(alignment: .leading, spacing: 8) {
                                        ForEach(operation.warnings, id: \.self) { Text($0).foregroundStyle(.orange) }
                                        ForEach(operation.order, id: \.self) { id in
                                            HStack {
                                                Text(result.services.first { $0.id == id }?.name ?? id)
                                                Spacer()
                                                Text(operation.statuses[id] ?? "waiting").foregroundStyle(.secondary)
                                            }
                                        }
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            DisclosureGroup("Warnings (\(result.warnings.count))") {
                                warnings(result.warnings)
                            }
                            if !result.services.contains(where: {
                                $0.runModes.local.available || $0.runModes.compose.available || $0.runModes.dockerfile.available
                            }) && result.composeServices.isEmpty {
                                ContentUnavailableView("Nothing runnable detected in this folder", systemImage: "magnifyingglass")
                                warnings(result.warnings)
                            }
                            ServiceLogsPanel(project: project, services: result.services, requestedSelection: logServiceID)
                            if !result.services.isEmpty {
                                sectionTitle("Services", count: result.services.count)
                                ForEach(result.services) { service in
                                    ServiceCard(project: project, service: service, environment: result.envRequirements.first { $0.serviceId == service.id })
                                }
                            }
                            if !result.infra.isEmpty {
                                sectionTitle("Infra", count: result.infra.count)
                                ForEach(result.infra, id: \.id) { infra in
                                    InfraCard(infra: infra, services: result.services)
                                }
                            }
                            if !result.composeFiles.isEmpty {
                                sectionTitle("Compose", count: result.composeFiles.count)
                                ForEach(result.composeFiles, id: \.self) { file in
                                    ComposeFileCard(file: file, result: result)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(24)
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
                Button("Rescan", action: onRescan)
            }
        } else {
            ContentUnavailableView {
                Label("Scan failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text("Rescan to try again.")
            } actions: {
                Button("Rescan", action: onRescan)
            }
        }
    }

    private func header(_ result: ScanResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(project.name).font(.title.bold())
                Spacer()
                if isScanning { ProgressView().controlSize(.small) }
                Menu("Start all") {
                    ForEach(ProjectStartMode.allCases) { mode in
                        Button(mode.rawValue) { requestStart(mode) }
                    }
                }.disabled(appState.projectOperations[project.id]?.busy == true || isScanning)
                Button("Stop all") { Task { await appState.stopAll(project: project) } }
                    .disabled(appState.projectOperations[project.id]?.busy == true)
                Button("Rescan", systemImage: "arrow.clockwise", action: onRescan)
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
