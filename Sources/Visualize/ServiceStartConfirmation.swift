import Foundation

struct ServiceStartConfirmation: Identifiable {
    let id = UUID()
    let mode: ServiceMode
    let recipe: RunRecipe?
}
