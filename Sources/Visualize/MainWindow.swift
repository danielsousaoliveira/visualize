import AppKit
import SwiftUI

struct MainWindow: View {
    static let id = "main"

    @Environment(AppState.self) private var appState
    @State private var pendingRemoval: Project?

    var body: some View {
        NavigationSplitView {
            sidebar
                .safeAreaInset(edge: .bottom) { DockerStatusView().padding() }
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
                .toolbar {
                    ToolbarItem {
                        Button("Add project", systemImage: "plus", action: addProject)
                    }
                }
        } detail: {
            detail
        }
        .frame(minWidth: 720, minHeight: 440)
        .sheet(item: Binding(get: { appState.portConflict }, set: { appState.portConflict = $0 })) { conflict in
            PortConflictSheet(conflict: conflict)
        }
        .alert("Port lookup failed", isPresented: Binding(get: { appState.portLookupError != nil }, set: { if !$0 { appState.portLookupError = nil } })) {
            Button("OK") { appState.portLookupError = nil }
        } message: {
            Text(appState.portLookupError ?? "")
        }
        .confirmationDialog(
            "Remove \(pendingRemoval?.name ?? "project") from visualize?",
            isPresented: isConfirmingRemoval,
            titleVisibility: .visible,
            presenting: pendingRemoval
        ) { project in
            Button("Remove", role: .destructive) { appState.remove(project.id) }
        } message: { _ in
            Text("The folder and its files stay on disk.")
        }
        .alert(
            "Project library",
            isPresented: isShowingLibraryError,
            actions: { Button("OK") {} },
            message: { Text(appState.libraryError ?? "") }
        )
    }

    @ViewBuilder
    private var sidebar: some View {
        @Bindable var appState = appState
        if appState.projects.isEmpty {
            ContentUnavailableView {
                Label("No projects yet", systemImage: "folder")
            } actions: {
                Button("Add project", action: addProject)
            }
        } else {
            List(selection: $appState.selection) {
                ForEach(appState.projects) { project in
                    ProjectRow(project: project, isScanning: appState.isScanning(project.id))
                        .tag(project.id)
                        .contextMenu { menu(for: project) }
                }
            }
            .onDeleteCommand {
                pendingRemoval = appState.selectedProject
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let project = appState.selectedProject {
            ProjectDetailView(
                project: project,
                isScanning: appState.isScanning(project.id),
                error: appState.scanErrors[project.id],
                onRescan: { rescan(project) },
                onLocate: { locate(project) },
                onRemove: { pendingRemoval = project }
            )
            .id(project.id)
            .navigationTitle(project.name)
            .toolbar {
                ToolbarItemGroup {
                    Button("Reveal in Finder", systemImage: "folder") { reveal(project) }
                        .disabled(!project.folderExists)
                    Button("Rescan", systemImage: "arrow.clockwise") { rescan(project) }
                        .disabled(!project.folderExists || appState.isScanning(project.id))
                }
            }
        } else {
            ContentUnavailableView("No project selected", systemImage: "square.dashed")
        }
    }

    @ViewBuilder
    private func menu(for project: Project) -> some View {
        let isScanning = appState.isScanning(project.id)
        if project.folderExists {
            Button("Rescan") { rescan(project) }
                .disabled(isScanning)
            Button("Reveal in Finder") { reveal(project) }
        } else {
            Button("Locate…") { locate(project) }
                .disabled(isScanning)
        }
        Divider()
        Button("Remove…", role: .destructive) { pendingRemoval = project }
    }

    private var isConfirmingRemoval: Binding<Bool> {
        Binding(
            get: { pendingRemoval != nil },
            set: { if !$0 { pendingRemoval = nil } }
        )
    }

    private var isShowingLibraryError: Binding<Bool> {
        Binding(
            get: { appState.libraryError != nil },
            set: { if !$0 { appState.libraryError = nil } }
        )
    }

    private func addProject() {
        guard let folder = FolderPicker.choose(prompt: "Add") else { return }
        Task { await appState.addProject(folder: folder) }
    }

    private func rescan(_ project: Project) {
        Task { await appState.rescan(project.id) }
    }

    private func locate(_ project: Project) {
        let parent = project.folderURL.deletingLastPathComponent()
        guard let folder = FolderPicker.choose(prompt: "Locate", startingAt: parent) else { return }
        Task { await appState.locate(project.id, at: folder) }
    }

    private func reveal(_ project: Project) {
        NSWorkspace.shared.activateFileViewerSelecting([project.folderURL])
    }
}
