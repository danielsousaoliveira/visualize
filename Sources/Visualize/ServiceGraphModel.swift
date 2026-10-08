import Foundation
import Observation

@MainActor
@Observable
final class ServiceGraphModel {
    private(set) var graph: ServiceGraph
    private let savePosition: (String, GraphPosition?) -> Void

    init(graph: ServiceGraph, savePosition: @escaping (String, GraphPosition?) -> Void) {
        self.graph = graph
        self.savePosition = savePosition
    }

    func moveNode(_ nodeID: String, to position: GraphPosition) {
        guard graph.positions[nodeID] != nil, position.x.isFinite, position.y.isFinite else { return }
        graph.positions[nodeID] = position
        savePosition(nodeID, position)
    }

    func replaceGraph(_ graph: ServiceGraph) {
        self.graph = graph
    }
}
