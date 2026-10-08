import Foundation

struct ServiceGraphEdge: Identifiable, Hashable {
    var id: Int
    var from: String
    var to: String
    var kind: ScanConnectionKind
    var label: String
    var isCyclic = false
    var reversedForLayout = false
}
