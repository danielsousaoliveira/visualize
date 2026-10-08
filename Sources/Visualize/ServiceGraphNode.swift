import Foundation

struct ServiceGraphNode: Identifiable, Hashable {
    var id: String
    var name: String
    var kind: ScanServiceKind?
    var infraKinds: [ScanInfraKind]
}
