import SwiftUI

struct ProjectGraphView: View {
    @Environment(AppState.self) private var appState
    let project: Project
    let model: ServiceGraphModel
    let onLogs: (String) -> Void
    @State private var zoom: CGFloat = 1
    @State private var offset = CGSize(width: 160, height: 100)
    @State private var panOrigin: CGSize?
    @State private var nodeOrigin: GraphPosition?
    @State private var draggingNode: String?
    @State private var dragPosition: GraphPosition?
    @State private var selected: String?
    @State private var pinchOrigin: CGFloat?

    private var graph: ServiceGraph { model.graph }

    var body: some View {
        if graph.nodes.isEmpty {
            ContentUnavailableView("Nothing to graph", systemImage: "point.3.connected.trianglepath.dotted")
        } else {
            HStack(spacing: 0) {
                GeometryReader { geometry in
                    VStack(spacing: 0) {
                        HStack {
                            Text(project.name).font(.headline)
                            Spacer()
                            Button("−") { changeZoom(zoom / 1.2, size: geometry.size) }
                                .accessibilityLabel("Zoom out")
                            Text("\(Int((zoom * 100).rounded()))%").monospacedDigit().frame(width: 48)
                            Button("+") { changeZoom(zoom * 1.2, size: geometry.size) }
                                .accessibilityLabel("Zoom in")
                            Button("Fit") { fit(geometry.size) }
                            Button("Reset layout") {
                                appState.resetGraphLayout(projectID: project.id)
                                fit(geometry.size)
                            }
                        }.padding(12)
                        ZStack(alignment: .topLeading) {
                            GraphScrollView { x, y, command in
                                if command { changeZoom(zoom * exp(y * 0.01), size: geometry.size) }
                                else { offset.width += x; offset.height += y }
                            }
                            .contentShape(Rectangle())
                            .gesture(DragGesture().onChanged { value in
                                if panOrigin == nil { panOrigin = offset }
                                offset = CGSize(width: panOrigin!.width + value.translation.width, height: panOrigin!.height + value.translation.height)
                            }.onEnded { _ in panOrigin = nil })
                            Canvas { context, _ in drawEdges(&context) }.allowsHitTesting(false)
                            ForEach(graph.nodes) { node in
                                if let position = position(node.id) {
                                    GraphNodeCard(project: project, node: node, selected: selected == node.id)
                                        .scaleEffect(zoom)
                                        .position(screen(position))
                                        .onTapGesture { selected = node.id }
                                        .gesture(DragGesture(minimumDistance: 5).onChanged { value in
                                            if draggingNode != node.id {
                                                draggingNode = node.id
                                                nodeOrigin = model.graph.positions[node.id]
                                            }
                                            guard let origin = nodeOrigin else { return }
                                            dragPosition = GraphPosition(x: origin.x + value.translation.width / zoom, y: origin.y + value.translation.height / zoom)
                                        }.onEnded { _ in
                                            if let dragPosition { model.moveNode(node.id, to: dragPosition) }
                                            draggingNode = nil
                                            nodeOrigin = nil
                                            dragPosition = nil
                                        })
                                }
                            }
                        }
                        .clipped()
                        .simultaneousGesture(MagnificationGesture().onChanged { value in
                            if pinchOrigin == nil { pinchOrigin = zoom }
                            changeZoom(pinchOrigin! * value, size: geometry.size)
                        }.onEnded { _ in pinchOrigin = nil })
                        .background(Color.primary.opacity(0.025))
                    }
                    .onAppear { fit(geometry.size) }
                }
                if let node = graph.nodes.first(where: { $0.id == selected }) {
                    Divider()
                    inspector(node).frame(width: 350)
                }
            }
        }
    }

    private func position(_ id: String) -> GraphPosition? {
        draggingNode == id ? dragPosition ?? graph.positions[id] : graph.positions[id]
    }

    private func screen(_ position: GraphPosition) -> CGPoint {
        CGPoint(x: position.x * zoom + offset.width, y: position.y * zoom + offset.height)
    }

    private func changeZoom(_ value: CGFloat, size: CGSize) {
        let next = min(2, max(0.25, value))
        let centre = CGPoint(x: size.width / 2, y: max(0, size.height - 52) / 2)
        offset = CGSize(width: centre.x - (centre.x - offset.width) * next / zoom,
                        height: centre.y - (centre.y - offset.height) * next / zoom)
        zoom = next
    }

    private func fit(_ size: CGSize) {
        let positions = graph.positions.values
        guard let minX = positions.map(\.x).min(), let maxX = positions.map(\.x).max(),
              let minY = positions.map(\.y).min(), let maxY = positions.map(\.y).max() else { return }
        zoom = min(2, max(0.25, min(max(1, size.width - 64) / (maxX - minX + 240), max(1, size.height - 116) / (maxY - minY + 120))))
        offset = CGSize(width: size.width / 2 - (minX + maxX) / 2 * zoom,
                        height: max(0, size.height - 52) / 2 - (minY + maxY) / 2 * zoom)
    }

    private func drawEdges(_ context: inout GraphicsContext) {
        for edge in graph.edges {
            guard let from = position(edge.from), let to = position(edge.to) else { continue }
            let direction: CGFloat = from.x <= to.x ? 1 : -1
            let start = screen(GraphPosition(x: from.x + direction * 120, y: from.y))
            let end = screen(GraphPosition(x: to.x - direction * 120, y: to.y))
            let bend = max(60 * zoom, abs(end.x - start.x) / 2)
            let selfEdge = edge.from == edge.to
            let c1 = CGPoint(x: start.x + direction * bend, y: selfEdge ? start.y - 140 * zoom : start.y)
            let c2 = CGPoint(x: end.x - direction * bend, y: selfEdge ? end.y - 140 * zoom : end.y)
            var path = Path()
            path.move(to: start)
            path.addCurve(to: end, control1: c1, control2: c2)
            let color: Color = edge.isCyclic ? .orange : edge.kind == .workspaceDep ? .gray : .secondary
            let dash: [CGFloat] = edge.kind == .envURL ? [7 * zoom, 5 * zoom] : edge.kind == .usesInfra ? [2 * zoom, 5 * zoom] : []
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: (edge.kind == .workspaceDep ? 1 : 1.8) * zoom, dash: dash))
            let angle = atan2(end.y - c2.y, end.x - c2.x)
            var arrow = Path()
            arrow.move(to: end)
            arrow.addLine(to: CGPoint(x: end.x - cos(angle - 0.45) * 10 * zoom, y: end.y - sin(angle - 0.45) * 10 * zoom))
            arrow.addLine(to: CGPoint(x: end.x - cos(angle + 0.45) * 10 * zoom, y: end.y - sin(angle + 0.45) * 10 * zoom))
            arrow.closeSubpath()
            context.fill(arrow, with: .color(color))
            if !edge.label.isEmpty && (graph.nodes.count <= 40 || zoom >= 1) {
                let middle = CGPoint(x: (start.x + 3 * c1.x + 3 * c2.x + end.x) / 8,
                                     y: (start.y + 3 * c1.y + 3 * c2.y + end.y) / 8 - 10 * zoom)
                context.draw(Text(edge.label).font(.system(size: 11 * zoom)).foregroundColor(color), at: middle)
            }
        }
    }

    private func inspector(_ node: ServiceGraphNode) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(node.name).font(.title2.bold())
                    Spacer()
                    Button("Close", systemImage: "xmark") { selected = nil }.labelStyle(.iconOnly)
                }
                if let service = project.lastResult?.services.first(where: { $0.id == node.id }) {
                    ServiceCard(project: project, service: service, environment: project.lastResult?.envRequirements.first { $0.serviceId == service.id })
                    Button("Logs", systemImage: "terminal") {
                        _ = appState.logs(project: project, service: service)
                        onLogs(service.id)
                    }
                } else if let infra = project.lastResult?.infra.fillingMissingIds().first(where: { $0.id == node.id }) {
                    InfraCard(infra: infra, services: project.lastResult?.services ?? [])
                } else {
                    Text("No service information detected").foregroundStyle(.secondary)
                }
                connections("Incoming", edges: graph.edges.filter { $0.to == node.id }, incoming: true)
                connections("Outgoing", edges: graph.edges.filter { $0.from == node.id }, incoming: false)
            }.padding(16)
        }
    }

    private func connections(_ title: String, edges: [ServiceGraphEdge], incoming: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            if edges.isEmpty { Text("None").foregroundStyle(.secondary) }
            ForEach(edges) { edge in
                let id = incoming ? edge.from : edge.to
                Button { selected = id } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(graph.nodes.first { $0.id == id }?.name ?? id)
                        Text([edge.kind.rawValue, edge.label].filter { !$0.isEmpty }.joined(separator: " • "))
                            .font(.caption).foregroundStyle(edge.isCyclic ? Color.orange : Color.secondary)
                    }
                }.buttonStyle(.plain)
            }
        }
    }
}
