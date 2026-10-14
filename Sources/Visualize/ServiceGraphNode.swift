import Foundation

struct ServiceGraphNode: Identifiable, Hashable {
    var id: String
    var name: String
    var kind: ScanServiceKind?
    var infraKinds: [ScanInfraKind]
    var category: String? = nil

    var layoutPriority: Int {
        if !infraKinds.isEmpty { return 0 }
        return ["frontend", "fullstack", "static", "mobile"].contains(category ?? "") ? 2 : 1
    }
}
