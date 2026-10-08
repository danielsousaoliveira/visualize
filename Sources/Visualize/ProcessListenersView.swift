import SwiftUI

struct ProcessListenersView: View {
    @Environment(AppState.self) private var appState
    @State private var lowerPort = 1024
    @State private var upperPort = 65535

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Listening ports").font(.title2)
                Spacer()
                Text("\(appState.listenerStore.listeners.count) processes").foregroundStyle(.secondary)
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
            if appState.listenerStore.listeners.isEmpty {
                ContentUnavailableView("No matching listeners", systemImage: "dot.radiowaves.left.and.right", description: Text("User-owned TCP listeners appear here."))
            } else {
                Table(appState.listenerStore.listeners) {
                    TableColumn("Port") { Text(String($0.port)).monospacedDigit() }.width(min: 55, ideal: 65)
                    TableColumn("Process") { listener in VStack(alignment: .leading) { Text(listener.name); Text("pid \(listener.pid)").font(.caption).foregroundStyle(.secondary) } }.width(min: 100, ideal: 145)
                    TableColumn("Project") { listener in VStack(alignment: .leading) { Text(listener.projectName ?? "—"); if let branch = listener.gitBranch { Text(branch).font(.caption).foregroundStyle(.secondary) } } }.width(min: 100, ideal: 150)
                    TableColumn("Working directory") { Text($0.workingDirectory ?? "—").lineLimit(1).help($0.workingDirectory ?? "") }.width(min: 180, ideal: 270)
                    TableColumn("CPU") { Text($0.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "—").monospacedDigit() }.width(min: 55, ideal: 65)
                    TableColumn("Memory") { Text(memory($0.memoryBytes)).monospacedDigit() }.width(min: 70, ideal: 85)
                }
            }
        }
        .padding(24)
        .navigationTitle("Ports")
    }

    private func memory(_ bytes: UInt64?) -> String {
        guard let bytes else { return "—" }
        return ByteCountFormatStyle().format(Int64(clamping: bytes))
    }
}
