import SwiftUI

struct AppSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var lower = ""
    @State private var upper = ""
    @State private var docker = ""

    var body: some View {
        let settings = appState.settings
        Form {
            Toggle("Launch at login", isOn: Binding(get: { settings.launchAtLogin }, set: { settings.setLaunchAtLogin($0) }))
            if let error = settings.loginError { Text(error).foregroundStyle(.red) }
            Picker("Port scan interval", selection: Binding(get: { settings.scanInterval }, set: { settings.setInterval($0) })) {
                ForEach([1, 2, 5, 10], id: \.self) { Text("\($0) seconds").tag($0) }
            }
            LabeledContent("Port range") {
                HStack {
                    TextField("Start", text: $lower).accessibilityLabel("Start port")
                    Text("to")
                    TextField("End", text: $upper).accessibilityLabel("End port")
                }.frame(width: 200)
            }
            if let error = settings.rangeError { Text(error).foregroundStyle(.red) }
            Picker("Log retention per service", selection: Binding(get: { settings.logRetentionMB }, set: { settings.setRetention($0) })) {
                ForEach([10, 40, 100], id: \.self) { Text("\($0) MB").tag($0) }
            }
            TextField("Docker CLI path", text: $docker, prompt: Text("Auto-detect"))
            if let error = settings.dockerError { Text(error).foregroundStyle(.red) }
            Text(appState.dockerState.message).font(.caption).foregroundStyle(.secondary)
            Button("Reset to defaults") {
                settings.reset()
                loadFields()
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { settings.refreshLoginStatus(); loadFields() }
        .onChange(of: lower) { settings.setRange(lower: lower, upper: upper) }
        .onChange(of: upper) { settings.setRange(lower: lower, upper: upper) }
        .onChange(of: docker) { settings.setDockerPath(docker) }
    }

    private func loadFields() {
        lower = String(appState.settings.lowerPort)
        upper = String(appState.settings.upperPort)
        docker = appState.settings.dockerPath
    }
}
