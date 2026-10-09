import SwiftUI
import AppKit

struct MenuBarPopover: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openURL) private var openURL
    @State private var contentHeight: CGFloat = 60
    @State private var footerHeight: CGFloat = 60
    @State private var screenHeight: CGFloat = NSScreen.main?.visibleFrame.height ?? 700
    @State private var displayed: [ProcessListenerGroup] = []
    @State private var hovered: String?
    @State private var selected: String?
    @State private var busy: Set<String> = []
    @FocusState private var focused: String?

    private var rows: [ProcessListener] {
        let ids = Set(appState.listenerStore.listeners.map(\.id))
        return displayed.flatMap(\.listeners).filter { ids.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 12) {
            if rows.isEmpty {
                Text("Nothing running").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(displayed) { group in
                                HStack {
                                    Text(group.name).font(.headline).lineLimit(1)
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
                                    if rows.contains(where: { $0.id == listener.id }) {
                                        row(listener).id(listener.id)
                                    } else {
                                        Color.clear.frame(height: 48)
                                    }
                                }
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .background {
                            GeometryReader { geometry in
                                Color.clear
                                    .task(id: geometry.size.height) { contentHeight = geometry.size.height }
                            }
                        }
                    }
                    .frame(height: min(contentHeight, max(60, screenHeight - footerHeight - 48)))
                    .scrollDisabled(contentHeight <= max(60, screenHeight - footerHeight - 48))
                    .onChange(of: selected) { if let selected { proxy.scrollTo(selected) } }
                }
            }
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
            .background {
                GeometryReader { geometry in
                    Color.clear
                        .task(id: geometry.size.height) { footerHeight = geometry.size.height }
                }
            }
        }
        .padding(12)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
        .background { WidgetScreenReader { screenHeight = $0 } }
        .onAppear { update() }
        .onChange(of: appState.listenerStore.listeners.map(\.id)) { update() }
        .onChange(of: appState.listenerStore.lastScan) { update() }
        .onChange(of: hovered) { if hovered == nil { update() } }
        .onChange(of: appState.pendingWidgetStop?.id) { if appState.pendingWidgetStop == nil { update() } }
        .onChange(of: focused) { if let focused { selected = focused } }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.return) {
            guard let listener = rows.first(where: { $0.id == selected }) else { return .ignored }
            openPort(listener)
            return .handled
        }
        .onKeyPress(.delete) {
            guard let listener = rows.first(where: { $0.id == selected }) else { return .ignored }
            appState.pendingWidgetStop = listener
            return .handled
        }
        .confirmationDialog("Stop listening service?", isPresented: Binding(get: { appState.pendingWidgetStop != nil }, set: { if !$0 { appState.pendingWidgetStop = nil } }), titleVisibility: .visible, presenting: appState.pendingWidgetStop) { listener in
            Button("Stop \(listener.serviceName ?? listener.name)", role: .destructive) { act(listener, externalStopConfirmed: true) }.help("Stop this service")
            Button("Cancel", role: .cancel) {}.help("Cancel")
        } message: { listener in
            Text("Stop the service on port \(listener.port)? The external listening process receives SIGTERM.")
        }
    }

    private func row(_ listener: ProcessListener) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(listener.serviceName ?? listener.name).lineLimit(1)
                HStack(spacing: 6) {
                    Text(listener.container == nil ? "process" : "container")
                        .padding(.horizontal, 5).background(.quaternary, in: Capsule())
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(uptime(listener, now: context.date)).monospacedDigit()
                    }
                }.font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button(String(listener.port)) { selected = listener.id; openPort(listener) }
                .buttonStyle(.link).monospacedDigit()
                .help("Open localhost:\(listener.port) in the browser")
            HStack(spacing: 6) {
                Button { requestStop(listener) } label: { Image(systemName: "stop.fill") }
                    .help("Stop")
                Button { act(listener, restart: true) } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(!appState.widgetRestartAvailable(listener))
                    .help(appState.widgetRestartAvailable(listener) ? "Restart" : "Not started by visualize")
            }
            .buttonStyle(.borderless)
            .disabled(busy.contains(listener.id))
            .opacity(hovered == listener.id || focused == listener.id || selected == listener.id ? 1 : 0)
        }
        .padding(6)
        .background(selected == listener.id ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { selected = listener.id; focused = listener.id }
        .focusable().focused($focused, equals: listener.id)
        .onHover { inside in
            if inside { hovered = listener.id }
            else if hovered == listener.id { hovered = nil }
        }
        .accessibilityElement(children: .contain)
    }

    private func update() {
        let liveIDs = Set(appState.listenerStore.listeners.map(\.id))
        if let hovered, !liveIDs.contains(hovered) { self.hovered = nil }
        if let selected, !liveIDs.contains(selected) { self.selected = nil }
        if let focused, !liveIDs.contains(focused) { self.focused = nil }
        if hovered != nil || appState.pendingWidgetStop != nil {
            let current = Dictionary(uniqueKeysWithValues: appState.listenerStore.listeners.map { ($0.id, $0) })
            displayed = displayed.map { group in
                ProcessListenerGroup(id: group.id, name: group.name, listeners: group.listeners.map { current[$0.id] ?? $0 })
            }
            return
        }
        displayed = ProcessListenerGroup.groups(appState.listenerStore.listeners).sorted {
            if ($0.id == "other") != ($1.id == "other") { return $1.id == "other" }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func move(_ offset: Int) {
        guard !rows.isEmpty else { return }
        let index = selected.flatMap { id in rows.firstIndex { $0.id == id } } ?? (offset > 0 ? -1 : rows.count)
        let next = min(rows.count - 1, max(0, index + offset))
        selected = rows[next].id
        focused = rows[next].id
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

    private func openMainWindow() {
        if let listener = rows.first(where: { $0.id == selected }), let id = listener.libraryProjectID {
            appState.selection = id
        }
        openWindow(id: MainWindow.id)
        NSApp.activate(ignoringOtherApps: true)
    }
}
