import SwiftUI

struct MenuBarPopover: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 12) {
            if appState.runningServices.isEmpty {
                Text("Nothing running")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ForEach(appState.runningServices) { service in
                    Text(service.name)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Divider()

            HStack {
                Button("Open visualize", action: openMainWindow)
                    .keyboardShortcut(.defaultAction)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(12)
        .frame(width: 280)
    }

    private func openMainWindow() {
        openWindow(id: MainWindow.id)
        NSApp.activate(ignoringOtherApps: true)
    }
}
