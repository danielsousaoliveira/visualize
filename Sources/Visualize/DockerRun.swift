import Foundation

struct DockerRun {
    let command: DockerCommand
    let mode: ServiceMode
    let projectID: UUID
    let projectSlug: String
    let serviceName: String
    let composeArguments: [String]
    var containerIDs: [String]

    static func projectSlug(_ project: Project) -> String {
        "\(slug(project.name))-\(project.id.uuidString.prefix(8).lowercased())"
    }

    static func slug(_ value: String) -> String {
        let cleaned = String(value.lowercased().map { character in
            character.isASCII && (character.isLetter || character.isNumber || "-_".contains(character)) ? character : "-"
        }).trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return cleaned.isEmpty ? "project" : cleaned
    }
}
