import Foundation

struct ProcessListenerGroup: Identifiable {
    let id: String
    let name: String
    let listeners: [ProcessListener]

    static func groups(_ listeners: [ProcessListener]) -> [Self] {
        Dictionary(grouping: listeners) { listener in
            if let id = listener.libraryProjectID { return "library:\(id.uuidString)" }
            if listener.startedByVisualize { return "visualize:\(listener.projectName ?? "Unknown project")" }
            return "other"
        }.map { key, entries in
            Self(id: key, name: entries.first?.attributionGroup ?? "Other", listeners: entries)
        }.sorted { $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name }
    }
}
