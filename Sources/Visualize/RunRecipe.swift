import Foundation

struct RunRecipe: Codable, Hashable {
    let argv: [String]
    let workingDirectory: String
    let addedEnvironmentKeys: [String]
    let startedAt: Date

    var approvalKey: String {
        String(data: try! JSONEncoder().encode([argv, [workingDirectory]]), encoding: .utf8)!
    }

    var displayCommand: String {
        argv.map { argument in
            if !argument.isEmpty && argument.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_./:@%+=,-".contains($0)) }) { return argument }
            return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
    }
}
