import SwiftUI
import AppKit

struct DatabaseConnectionsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var settings = DatabaseConnectionSettings()
    @State private var password = ""
    @State private var candidates: [DatabaseCandidate] = []
    @State private var warnings: [String] = []
    @State private var message: String?
    @State private var failed = false
    @State private var busy = false
    @State private var loading = true
    let project: Project

    private var saved: [DatabaseConnectionSettings] {
        appState.project(project.id)?.databaseConnections ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Local databases").font(.title2.bold())
            Text("Connect read-only to a database for \(project.name). Passwords are saved in macOS Keychain.")
                .foregroundStyle(.secondary)
            HStack {
                Menu("Saved connections") {
                    ForEach(saved) { connection in
                        Button(connection.name) { edit(connection) }.help("Edit this saved connection")
                    }
                }.disabled(saved.isEmpty).help("Choose a saved database connection")
                Menu("Detected connections") {
                    ForEach(candidates) { candidate in
                        Button(candidate.source) { use(candidate) }.help("Use this detected database connection")
                    }
                }.disabled(candidates.isEmpty).help("Choose a database detected in this project")
                Button("New connection") {
                    settings = DatabaseConnectionSettings()
                    password = ""
                    message = nil
                }.help("New connection")
                if loading { ProgressView().controlSize(.small) }
            }
            if settings.engine == .postgres {
                Text("Postgres requires a dedicated reader role. Connections with write or administrative privileges are rejected.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Form {
                TextField("Name", text: $settings.name)
                Picker("Engine", selection: $settings.engine) {
                    ForEach(DatabaseConnectionSettings.Engine.allCases, id: \.self) { engine in
                        Text(engine.rawValue).tag(engine)
                    }
                }
                if settings.engine == .postgres {
                    TextField("Host", text: $settings.host)
                    TextField("Port", value: $settings.port, format: .number.grouping(.never))
                    TextField("User", text: $settings.user)
                    SecureField("Password", text: $password)
                    TextField("Database", text: $settings.database)
                } else {
                    HStack {
                        TextField("File", text: $settings.filePath)
                        Button("Choose…", action: chooseFile).help("Choose…")
                    }
                }
            }
            if !warnings.isEmpty {
                DisclosureGroup("Discovery warnings (\(warnings.count))") {
                    ScrollView {
                        VStack(alignment: .leading) {
                            ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
                                Text(warning).font(.callout).foregroundStyle(.secondary)
                            }
                        }
                    }.frame(maxHeight: 120)
                }
            }
            if let message {
                Text(message).foregroundStyle(failed ? .red : .green).textSelection(.enabled)
            }
            if appState.databaseSessions[settings.id] != nil {
                Label("Connected read-only", systemImage: "lock.fill").foregroundStyle(.secondary)
                Button("Disconnect") { appState.disconnectDatabase(settings.id); message = nil }.help("Disconnect")
            }
            HStack {
                if saved.contains(where: { $0.id == settings.id }) {
                    Button("Delete", role: .destructive) {
                        report {
                            try appState.deleteDatabaseConnection(settings, projectID: project.id)
                            settings = DatabaseConnectionSettings()
                            password = ""
                            message = "Connection deleted"
                        }
                    }.help("Delete")
                }
                Spacer()
                Button("Test connection") { connect(retain: false) }.help("Test connection")
                Button("Save") {
                    report {
                        try appState.saveDatabaseConnection(settings, password: password, projectID: project.id)
                        message = "Connection saved"
                    }
                }.help("Save")
                Button("Connect") { connect(retain: true) }.help("Connect")
            }
            .disabled(busy || loading)
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Close") { dismiss() }.help("Close").keyboardShortcut(.cancelAction).disabled(busy)
            }
        }
        .padding(24)
        .frame(width: 620)
        .disabled(busy)
        .task {
            let result = await DatabaseDiscovery.discover(project: project, dockerOverride: appState.dockerOverridePath)
            candidates = result.candidates
            warnings = result.warnings
            if let first = saved.first { edit(first) }
            else if let first = candidates.first { use(first) }
            loading = false
        }
        .onChange(of: settings) { old, new in
            if old.id == new.id { appState.disconnectDatabase(old.id) }
            message = nil
        }
        .onChange(of: password) { _, _ in
            appState.disconnectDatabase(settings.id)
            message = nil
        }
    }

    private func use(_ candidate: DatabaseCandidate) {
        settings = candidate.settings
        password = candidate.password
        message = nil
    }

    private func edit(_ connection: DatabaseConnectionSettings) {
        report {
            let value = try DatabasePasswordStore.read(projectID: project.id, connectionID: connection.id)
            settings = connection
            password = value
            message = nil
        }
    }

    private func chooseFile() {
        let picker = NSOpenPanel()
        picker.canChooseDirectories = false
        picker.canChooseFiles = true
        picker.allowsMultipleSelection = false
        if picker.runModal() == .OK, let url = picker.url { settings.filePath = url.path }
    }

    private func report(_ action: () throws -> Void) {
        do { failed = false; try action() }
        catch { failed = true; message = error.localizedDescription }
    }

    private func connect(retain: Bool) {
        let configuration = settings
        let secret = password
        busy = true
        message = nil
        Task {
            do {
                let connection = try await Task.detached {
                    try DatabaseConnection(settings: configuration, password: secret)
                }.value
                do {
                    let version = try await connection.version()
                    if retain {
                        try appState.retainDatabase(connection, id: configuration.id, projectID: project.id)
                    } else { await connection.close() }
                    failed = false
                    message = "\(retain ? "Connected read-only" : "Connection successful"): \(version)"
                } catch { await connection.close(); throw error }
            } catch {
                failed = true
                message = error.localizedDescription
            }
            busy = false
        }
    }
}
