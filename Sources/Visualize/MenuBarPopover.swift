import SwiftUI
import AppKit

struct MenuBarPopover: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openURL) private var openURL
    @State private var screenHeight: CGFloat = NSScreen.main?.visibleFrame.height ?? 700
    private var displayed: [ProcessListenerGroup] {
        ProcessListenerGroup.groups(appState.listenerStore.listeners).sorted {
            if ($0.id == "other") != ($1.id == "other") { return $1.id == "other" }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    @State private var hovered: String?
    @State private var busy: Set<String> = []
    @State private var showOther = false

    private var rows: [ProcessListener] {
        displayed.filter { showOther || $0.id != "other" }.flatMap(\.listeners)
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Running services").font(.headline)
                Spacer()
                Text("\(appState.listenerStore.listeners.count)").font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }.padding(.horizontal, 4)
            ScrollView { listenerList }
                .frame(height: min(max(72, CGFloat(rows.count * 76 + displayed.count * 40)), max(72, screenHeight - 190)))
            VStack(spacing: 12) {
                if appState.dockerState.unavailableReason() != nil {
                    Text("Container ports are not shown").font(.caption).foregroundStyle(.secondary)
                }
                if let error = appState.listenerStore.actionError ?? appState.portLookupError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Divider()
                HStack {
                    Button("Open visualize", action: openMainWindow)
                        .help("Bring visualize to the front")
                    Spacer()
                    Button("Quit") { NSApp.terminate(nil) }
                        .help("Quit visualize")
                }
            }
        }
        .tint(.primary)
        .padding(12)
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
        .background { WidgetScreenReader { screenHeight = $0 } }
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
        .onAppear { update() }
        .onChange(of: showOther) { update() }
        .onChange(of: appState.listenerStore.listeners.map(\.id)) { update() }
        .onChange(of: appState.listenerStore.lastScan) { update() }
        .onChange(of: hovered) { if hovered == nil { update() } }
        .onChange(of: appState.pendingWidgetStop?.id) { if appState.pendingWidgetStop == nil { update() } }
        .confirmationDialog("Stop listening service?", isPresented: Binding(get: { appState.pendingWidgetStop != nil }, set: { if !$0 { appState.pendingWidgetStop = nil } }), titleVisibility: .visible, presenting: appState.pendingWidgetStop) { listener in
            Button("Stop \(listener.serviceName ?? listener.name)", role: .destructive) { act(listener, externalStopConfirmed: true) }.help("Stop this service")
            Button("Cancel", role: .cancel) {}.help("Cancel")
        } message: { listener in
            Text("Stop the service on port \(listener.port)? The external listening process receives SIGTERM.")
        }
    }

    private var listenerList: some View {
        VStack(alignment: .leading, spacing: 12) {
            if displayed.isEmpty {
                Text("Nothing running")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ForEach(displayed) { group in
                    if group.id == "other" {
                        DisclosureGroup("Other listeners (\(group.listeners.count))", isExpanded: $showOther) {
                            ForEach(group.listeners) { listener in row(listener).id(listener.id) }
                        }
                    } else {
                    HStack {
                        Button { openProject(projectID(group.listeners.first)) } label: {
                            HStack(spacing: 8) {
                                TechnologyIcon(technology: technology(group.listeners.first), size: 16)
                                Text(group.name).font(.headline).lineLimit(1)
                                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                            }
                        }.buttonStyle(.plain).help(projectID(group.listeners.first) == nil ? "Open visualize" : "Open this project in visualize")
                        Spacer()
                        if group.id != "other" && appState.widgetStopManagedAvailable(group) {
                            Button("Stop managed") {
                                Task { await appState.widgetStopManaged(group) }
                            }
                            .font(.caption)
                            .help("Stop managed services shown in this group")
                        }
                    }
                    ForEach(group.listeners) { listener in
                        row(listener).id(listener.id)
                    }
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func row(_ listener: ProcessListener) -> some View {
        HStack(spacing: 8) {
            Button { openProject(projectID(listener)) } label: {
            HStack(spacing: 10) {
            TechnologyIcon(technology: technology(listener), size: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(listener.serviceName ?? listener.container?.name ?? processName(listener)).lineLimit(1)
                    .help(listener.container.map { "\($0.name) · \($0.image)" } ?? "PID \(listener.pid) · \(listener.executablePath ?? listener.name)\n\(listener.workingDirectory ?? "Working directory unavailable")")
                if listener.libraryProjectID == nil {
                    Text(listener.container?.image ?? "\(listener.processExplanation) · PID \(listener.pid)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if let branch = listener.gitBranch {
                    Text(branch).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(branch)
                }
                HStack(spacing: 6) {
                    Text(listener.container == nil ? "process" : "container")
                        .padding(.horizontal, 5).background(.quaternary, in: Capsule())
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(uptime(listener, now: context.date)).monospacedDigit()
                    }
                }.font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            }.buttonStyle(.plain).help(projectID(listener) == nil ? "Open visualize" : "Open this project in visualize")
            Button(String(listener.port)) { openPort(listener) }
                .buttonStyle(.plain).font(.callout.monospacedDigit()).foregroundStyle(.primary)
                .help("Open localhost:\(listener.port) in the browser")
            HStack(spacing: 6) {
                Button { requestStop(listener) } label: { Image(systemName: "stop") }
                    .help("Stop")
                Button { act(listener, restart: true) } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(!appState.widgetRestartAvailable(listener))
                    .help(appState.widgetRestartAvailable(listener) ? "Restart" : "Not started by visualize")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12, weight: .light))
            .disabled(busy.contains(listener.id))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(hovered == listener.id ? Color.primary.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .onHover { inside in
            if inside { hovered = listener.id }
            else if hovered == listener.id { hovered = nil }
        }
        .accessibilityElement(children: .contain)
    }

    private func update() {
        let liveIDs = Set(rows.map(\.id))
        if let hovered, !liveIDs.contains(hovered) { self.hovered = nil }
    }

    private func processName(_ listener: ProcessListener) -> String {
        guard let path = listener.executablePath, !path.isEmpty else { return listener.name }
        let executable = URL(filePath: path).lastPathComponent
        if executable == "java", listener.workingDirectory?.contains("/.gradle/daemon/") == true { return "Gradle daemon" }
        if executable == "java", listener.workingDirectory?.contains("/kotlin/daemon") == true { return "Kotlin compiler daemon" }
        return executable
    }

    private func openPort(_ listener: ProcessListener) {
        if let url = URL(string: "http://localhost:\(listener.port)") { openURL(url) }
    }

    private func requestStop(_ listener: ProcessListener) {
        if listener.container == nil && !listener.startedByVisualize { appState.pendingWidgetStop = listener }
        else { act(listener) }
    }

    private func act(_ listener: ProcessListener, restart: Bool = false, externalStopConfirmed: Bool = false) {
        guard busy.insert(listener.id).inserted else { return }
        Task {
            await appState.widgetAction(listener, restart: restart, externalStopConfirmed: externalStopConfirmed)
            busy.remove(listener.id)
        }
    }

    private func uptime(_ listener: ProcessListener, now: Date) -> String {
        let start = listener.container?.startedAt ?? listener.startedAt.map {
            Date(timeIntervalSince1970: Double($0.seconds) + Double($0.microseconds) / 1_000_000)
        }
        guard let start else { return "—" }
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        if seconds >= 3600 { return "\(seconds / 3600)h \(seconds % 3600 / 60)m" }
        if seconds >= 60 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds)s"
    }

    private func projectID(_ listener: ProcessListener?) -> UUID? {
        guard let listener else { return nil }
        if let id = listener.libraryProjectID { return id }
        return appState.projects.sorted { $0.folderPath.count > $1.folderPath.count }.first { project in
            [listener.repositoryRoot, listener.workingDirectory].compactMap { $0 }.contains { path in
                path == project.folderPath || path.hasPrefix(project.folderPath + "/")
            }
        }?.id
    }

    private func technology(_ listener: ProcessListener?) -> String? {
        guard let listener else { return nil }
        if let project = appState.projects.first(where: { $0.id == projectID(listener) }) {
            return project.lastResult?.services.first(where: { $0.id == listener.serviceID })?.stackId
                ?? project.lastResult?.services.compactMap(\.stackId).first
        }
        return listener.container?.image.components(separatedBy: ":").first ?? processName(listener)
    }

    private func openProject(_ id: UUID?) {
        if let id { appState.selection = id }
        openMainWindow()
    }

    private func openMainWindow() {
        openWindow(id: MainWindow.id)
        NSApp.activate(ignoringOtherApps: true)
    }
}
