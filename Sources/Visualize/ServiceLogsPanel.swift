import SwiftUI
import AppKit

struct ServiceLogsPanel: View {
    @Environment(AppState.self) private var appState
    @State private var selected: String?
    @State private var expanded = false
    let project: Project
    let services: [ScanService]
    var requestedSelection: String? = nil

    private var available: [ScanService] {
        let previous = appState.launchedServices[project.id, default: [:]].values
            .filter { previous in !services.contains { $0.id == previous.id } }
            .sorted { $0.name < $1.name }
        return (services + previous).filter {
            let key = appState.runKey(project: project, service: $0)
            return appState.serviceRuns[key] != nil || appState.serviceLogs[key] != nil
        }
    }

    var body: some View {
        if !available.isEmpty {
            DisclosureGroup("Service logs", isExpanded: $expanded) {
                if expanded {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Spacer()
                            Picker("Service", selection: Binding(
                                get: { selected ?? available.first?.id ?? "" },
                                set: { selected = $0 }
                            )) {
                                ForEach(available) { service in
                                    Text(service.name).tag(service.id)
                                }
                            }
                            .pickerStyle(.menu)
                            .fixedSize()
                            .help("Choose the service whose logs to show")
                        }
                        if let service = available.first(where: { $0.id == (selected ?? available.first?.id) }) {
                            ServiceLogView(log: appState.logs(project: project, service: service), docker: appState.serviceRuns[appState.runKey(project: project, service: service)]?.docker, directory: project.folderPath)
                                .id(service.id)
                        }
                    }.padding(.top, 12)
                }
            }
            .onAppear { if let requestedSelection { selected = requestedSelection; expanded = true } }
            .help("Show or hide service logs")
            .onChange(of: available.map(\.id), initial: true) {
                if !available.contains(where: { $0.id == selected }) { selected = available.first?.id }
            }
            .onChange(of: requestedSelection) { _, value in
                if let value { selected = value; expanded = true }
            }
        }
    }
}
