import SwiftUI

struct ProcessListenersView: View {
    @Environment(AppState.self) private var appState
    @State private var pendingStop: DockerContainer?
    @State private var lowerPort = 1024
    @State private var upperPort = 65535

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Listening ports").font(.title2)
                Spacer()
                Text("\(appState.listenerStore.listeners.count) listeners").foregroundStyle(.secondary)
            }
            HStack {
                Text("Ports")
                TextField("From", value: $lowerPort, format: .number).frame(width: 84)
                Text("to")
                TextField("To", value: $upperPort, format: .number).frame(width: 84)
                Button("Apply") {
                    appState.listenerStore.lowerPort = lowerPort
                    appState.listenerStore.upperPort = upperPort
                }
                Spacer()
                if let scanned = appState.listenerStore.lastScan {
                    Text("Updated \(scanned.formatted(date: .omitted, time: .standard))").foregroundStyle(.secondary)
                }
            }
            if let error = appState.listenerStore.actionError { Text(error).foregroundStyle(.red) }
            if appState.listenerStore.listeners.isEmpty {
                ContentUnavailableView("No matching listeners", systemImage: "dot.radiowaves.left.and.right", description: Text("User-owned TCP listeners appear here."))
            } else {
                ScrollView {
                    ForEach(ProcessListenerGroup.groups(appState.listenerStore.listeners)) { group in
                        Text(group.name).font(.headline).frame(maxWidth: .infinity, alignment: .leading)
                        Table(group.listeners) {
                            TableColumn("Port") { Text(String($0.port)).monospacedDigit() }.width(min: 55, ideal: 65)
                            TableColumn("Listener") { listener in
                                VStack(alignment: .leading) {
                                    Text(listener.name)
                                    Text(listener.container.map { "\($0.image) · \($0.status)" } ?? "pid \(listener.pid)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }.width(min: 100, ideal: 145)
                            TableColumn("Project") { listener in
                                VStack(alignment: .leading) {
                                    Text(listener.attributionLabel)
                                    Text(listener.attributionGroup).font(.caption).foregroundStyle(.secondary)
                                    if let branch = listener.gitBranch { Text(branch).font(.caption).foregroundStyle(.secondary) }
                                }
                            }.width(min: 100, ideal: 150)
                            TableColumn("Working directory") { Text($0.workingDirectory ?? "—").lineLimit(1).help($0.workingDirectory ?? "") }.width(min: 180, ideal: 270)
                            TableColumn("CPU") { Text($0.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "—").monospacedDigit() }.width(min: 55, ideal: 65)
                            TableColumn("Actions") { listener in
                                if let container = listener.container {
                                    HStack {
                                        Button("Stop") { pendingStop = container }
                                        Button("Restart") { Task { await appState.listenerStore.perform("restart", container: container, overridePath: appState.dockerOverridePath) } }.disabled(!listener.startedByVisualize)
                                    }.disabled(appState.listenerStore.busyContainers.contains(container.id))
                                }
                            }.width(min: 140, ideal: 150)
                            TableColumn("Memory") { Text(memory($0.memoryBytes)).monospacedDigit() }.width(min: 70, ideal: 85)
                        }.frame(height: CGFloat(group.listeners.count * 48 + 32))
                    }
                }
            }
        }
        .padding(24)
        .navigationTitle("Ports")
        .confirmationDialog("Stop container?", isPresented: Binding(get: { pendingStop != nil }, set: { if !$0 { pendingStop = nil } }), presenting: pendingStop) { container in
            Button("Stop \(container.name)", role: .destructive) {
                Task { await appState.listenerStore.perform("stop", container: container, overridePath: appState.dockerOverridePath) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { container in
            Text("Stop \(container.name) (\(container.image), ID \(container.id.prefix(12))) on ports \(container.ports.map(String.init).joined(separator: ", "))?")
        }
        .onAppear {
            lowerPort = appState.listenerStore.lowerPort
            upperPort = appState.listenerStore.upperPort
        }
    }

    private func memory(_ bytes: UInt64?) -> String {
        guard let bytes else { return "—" }
        return ByteCountFormatStyle().format(Int64(clamping: bytes))
    }
}
