import Foundation
import Observation
import ServiceManagement

@MainActor
@Observable
final class AppSettings {
    private(set) var scanInterval: Int
    private(set) var lowerPort: Int
    private(set) var upperPort: Int
    private(set) var logRetentionMB: Int
    private(set) var dockerPath: String
    private(set) var launchAtLogin = false
    var loginError: String?
    var rangeError: String?
    var dockerError: String?
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let defaults = UserDefaults.standard

    init() {
        let defaults = UserDefaults.standard
        let interval = defaults.integer(forKey: "scanInterval")
        scanInterval = [1, 2, 5, 10].contains(interval) ? interval : 2
        let lower = defaults.integer(forKey: "lowerPort")
        let upper = defaults.integer(forKey: "upperPort")
        let valid = (1...65535).contains(lower) && (lower...65535).contains(upper)
        lowerPort = valid ? lower : 1024
        upperPort = valid ? upper : 65535
        let retention = defaults.integer(forKey: "logRetentionMB")
        logRetentionMB = [10, 40, 100].contains(retention) ? retention : 40
        dockerPath = defaults.string(forKey: "dockerOverridePath") ?? ""
        refreshLoginStatus()
    }

    func refreshLoginStatus() {
        launchAtLogin = [.enabled, .requiresApproval].contains(SMAppService.mainApp.status)
        if SMAppService.mainApp.status == .requiresApproval {
            loginError = "Allow visualize in System Settings → General → Login Items."
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch { loginError = error.localizedDescription }
        refreshLoginStatus()
    }

    func setInterval(_ value: Int) {
        guard [1, 2, 5, 10].contains(value) else { return }
        scanInterval = value
        save()
    }

    func setRange(lower: String, upper: String) {
        guard let start = Int(lower), let end = Int(upper), (1...65535).contains(start), (1...65535).contains(end), start <= end else {
            rangeError = "Enter ports from 1 to 65535, with the start at or below the end."
            return
        }
        rangeError = nil
        lowerPort = start
        upperPort = end
        save()
    }

    func setRetention(_ value: Int) {
        guard [10, 40, 100].contains(value) else { return }
        logRetentionMB = value
        save()
    }

    func setDockerPath(_ value: String) {
        let path = NSString(string: value).expandingTildeInPath
        var directory: ObjCBool = false
        guard value.isEmpty || (NSString(string: path).isAbsolutePath && FileManager.default.fileExists(atPath: path, isDirectory: &directory) && !directory.boolValue && FileManager.default.isExecutableFile(atPath: path)) else {
            dockerError = "Choose an executable file, or leave the path empty for auto-detect."
            return
        }
        dockerError = nil
        dockerPath = path
        save()
    }

    func reset() {
        setLaunchAtLogin(false)
        scanInterval = 2
        lowerPort = 1024
        upperPort = 65535
        logRetentionMB = 40
        dockerPath = ""
        rangeError = nil
        dockerError = nil
        save()
    }

    private func save() {
        defaults.set(scanInterval, forKey: "scanInterval")
        defaults.set(lowerPort, forKey: "lowerPort")
        defaults.set(upperPort, forKey: "upperPort")
        defaults.set(logRetentionMB, forKey: "logRetentionMB")
        defaults.set(dockerPath.isEmpty ? nil : dockerPath, forKey: "dockerOverridePath")
        onChange?()
    }
}
