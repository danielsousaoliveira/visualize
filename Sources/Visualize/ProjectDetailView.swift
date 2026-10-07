import SwiftUI

struct ProjectDetailView: View {
    let project: Project
    let isScanning: Bool
    let error: String?
    let onRescan: () -> Void
    let onLocate: () -> Void
    let onRemove: () -> Void

    var body: some View {
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

    @ViewBuilder
    private var content: some View {
        if let result = project.lastResult {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    header(result)
                    DisclosureGroup("Warnings (\(result.warnings.count))") {
                        warnings(result.warnings)
                    }
                    if !result.services.contains(where: {
                        $0.runModes.local.available || $0.runModes.compose.available || $0.runModes.dockerfile.available
                    }) && result.composeServices.isEmpty {
                        ContentUnavailableView("Nothing runnable detected in this folder", systemImage: "magnifyingglass")
                        warnings(result.warnings)
                    }
                    if !result.services.isEmpty {
                        sectionTitle("Services", count: result.services.count)
                        ForEach(result.services) { service in
                            ServiceCard(service: service, environment: result.envRequirements.first { $0.serviceId == service.id })
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
                Button("Rescan", systemImage: "arrow.clockwise", action: onRescan)
                    .disabled(isScanning)
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
