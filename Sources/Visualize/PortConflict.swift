import Foundation

struct PortConflict: Identifiable {
    let id = UUID()
    let project: Project
    let service: ScanService
    let recipe: RunRecipe
    let environment: [String: String]?
    let owners: [PortOwner]
}
