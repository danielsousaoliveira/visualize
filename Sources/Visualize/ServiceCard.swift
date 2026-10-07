import SwiftUI

struct ServiceCard: View {
    @Environment(AppState.self) private var appState

    let service: ScanService
    let environment: ScanEnvRequirement?

    private var variables: [ScanEnvVariable] { environment?.variables ?? [] }
    private var missing: [ScanEnvVariable] { variables.filter { $0.status == .missing } }
    private var setCount: Int { variables.filter { $0.status != .missing }.count }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(service.name).font(.headline)
                    Spacer()
                    Text(service.rootDirectory).font(.callout.monospaced()).foregroundStyle(.secondary)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 20) { metadata }
                    VStack(alignment: .leading, spacing: 6) { metadata }
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
                HStack(spacing: 8) {
                    RunModeChip(title: "Local", available: service.runModes.local.available, reason: service.runModes.local.reason)
                    RunModeChip(title: "Compose", available: service.runModes.compose.available && appState.dockerState.unavailableReason(compose: true) == nil, reason: appState.dockerState.unavailableReason(compose: true) ?? service.runModes.compose.reason)
                    RunModeChip(title: "Dockerfile", available: service.runModes.dockerfile.available && appState.dockerState.unavailableReason() == nil, reason: appState.dockerState.unavailableReason() ?? service.runModes.dockerfile.reason)
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
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }

    @ViewBuilder
    private var metadata: some View {
        Text("\(service.stackId ?? "Unknown stack") • \(service.category ?? "Unclassified")")
        Text("Package manager: \(service.packageManager ?? "Not detected")")
        Text(service.port.map { "Port: \(String($0))" } ?? "Port: Not detected")
    }

    private func shellArgument(_ argument: String) -> String {
        if !argument.isEmpty && argument.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_./:@%+=,-".contains($0)) }) {
            return argument
        }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
