import Foundation

struct ListenerVisibility {
    static func isCodingAgent(_ listener: ProcessListener) -> Bool {
        guard listener.container == nil else { return false }
        let path = listener.executablePath ?? ""
        let name = URL(filePath: path).lastPathComponent.lowercased()
        let agents = ["codex", "cursor", "copilot", "opencode", "claude"]
        if agents.contains(name) || agents.contains(where: { name.hasPrefix($0 + "-") }) { return true }
        return path.split(separator: "/").contains { component in
            let bundle = component.lowercased()
            return agents.contains { bundle == $0 + ".app" }
        }
    }

    static func isDesktopOrSystem(_ listener: ProcessListener) -> Bool {
        guard listener.container == nil, !isCodingAgent(listener) else { return false }
        guard let path = listener.executablePath, !path.isEmpty else { return true }
        if ["/System/", "/usr/libexec/", "/usr/sbin/"].contains(where: { path.hasPrefix($0) }) { return true }
        let name = URL(filePath: path).lastPathComponent.lowercased()
        let runtimes = ["python", "python3", "java", "node", "bun", "deno", "ruby", "php", "dotnet", "postgres", "redis-server", "mongod"]
        if runtimes.contains(name) || name.hasPrefix("python3.") { return false }
        return path.split(separator: "/").contains { $0.lowercased().hasSuffix(".app") }
    }
}
