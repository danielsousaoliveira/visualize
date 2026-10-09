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
                            Button("−") { changeZoom(zoom / 1.2, size: geometry.size) }.help("Zoom out")
                                .accessibilityLabel("Zoom out")
                            Text("\(Int((zoom * 100).rounded()))%").monospacedDigit().frame(width: 48)
                            Button("+") { changeZoom(zoom * 1.2, size: geometry.size) }.help("Zoom in")
                                .accessibilityLabel("Zoom in")
                            Button("Fit") { fit(geometry.size) }.help("Fit the graph at up to 100% zoom")
                            Button("Reset layout") {
                                appState.resetGraphLayout(projectID: project.id)
                                fit(geometry.size)
                            }.help("Reset layout")
                        }.padding(12)
                        ZStack(alignment: .topLeading) {
                            GraphScrollView(onMagnify: { delta in
                                changeZoom(zoom * max(0.01, 1 + delta), size: geometry.size)
                            }) { x, y, command in
                                if command { changeZoom(zoom * exp(y * 0.01), size: geometry.size) }
                                else { offset.width += x; offset.height += y }
                            }
                            .contentShape(Rectangle())
                            .gesture(DragGesture().onChanged { value in
                                if panOrigin == nil { panOrigin = offset }
                                offset = CGSize(width: panOrigin!.width + value.translation.width, height: panOrigin!.height + value.translation.height)
                            }.onEnded { _ in panOrigin = nil })
                            Canvas { context, size in drawEdges(&context, size: size) }.allowsHitTesting(false)
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
        guard let left = positions.map({ $0.x - GraphNodeCard.size.width / 2 }).min(),
              let right = positions.map({ $0.x + GraphNodeCard.size.width / 2 }).max(),
              let top = positions.map({ $0.y - GraphNodeCard.size.height / 2 }).min(),
              let bottom = positions.map({ $0.y + GraphNodeCard.size.height / 2 }).max() else { return }
        let canvasHeight = max(1, size.height - 52)
        zoom = min(1, max(0.25, min(max(1, size.width - 64) / (right - left),
                                   max(1, canvasHeight - 64) / (bottom - top))))
        offset = CGSize(width: size.width / 2 - (left + right) / 2 * zoom,
                        height: canvasHeight / 2 - (top + bottom) / 2 * zoom)
    }

    private func drawEdges(_ context: inout GraphicsContext, size: CGSize) {
        let groups = Dictionary(grouping: graph.edges) { [$0.from, $0.to].sorted().joined(separator: "\u{0}") }
        var occupied = graph.nodes.compactMap { node -> CGRect? in
            guard let position = position(node.id) else { return nil }
            let centre = screen(position)
            return CGRect(x: centre.x - GraphNodeCard.size.width * zoom / 2,
                          y: centre.y - GraphNodeCard.size.height * zoom / 2,
                          width: GraphNodeCard.size.width * zoom,
                          height: GraphNodeCard.size.height * zoom).insetBy(dx: -6, dy: -6)
        }
        var labels: [(CGRect, GraphicsContext.ResolvedText)] = []
        let edges = graph.edges.sorted {
            let firstSelected = $0.from == selected || $0.to == selected
            let secondSelected = $1.from == selected || $1.to == selected
            return firstSelected == secondSelected ? $0.id < $1.id : firstSelected
        }
        for edge in edges {
            guard let from = position(edge.from), let to = position(edge.to) else { continue }
            let direction: CGFloat = from.x <= to.x ? 1 : -1
            let start = screen(GraphPosition(x: from.x + direction * GraphNodeCard.size.width / 2, y: from.y))
            let end = screen(GraphPosition(x: to.x - direction * GraphNodeCard.size.width / 2, y: to.y))
            let bend = max(60 * zoom, abs(end.x - start.x) / 2)
            let selfEdge = edge.from == edge.to
            let peers = groups[[edge.from, edge.to].sorted().joined(separator: "\u{0}")] ?? [edge]
            let lane = CGFloat(peers.firstIndex { $0.id == edge.id } ?? 0) - CGFloat(peers.count - 1) / 2
            let laneOffset = lane * 32 * zoom
            let c1 = CGPoint(x: start.x + direction * bend, y: (selfEdge ? start.y - 140 * zoom : start.y) + laneOffset)
            let c2 = CGPoint(x: end.x - direction * bend, y: (selfEdge ? end.y - 140 * zoom : end.y) + laneOffset)
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
            if !edge.label.isEmpty && zoom >= 0.75 && (graph.nodes.count <= 40 || edge.from == selected || edge.to == selected) {
                let middle = CGPoint(x: (start.x + 3 * c1.x + 3 * c2.x + end.x) / 8,
                                     y: (start.y + 3 * c1.y + 3 * c2.y + end.y) / 8 - 10 * zoom)
                let text = context.resolve(Text(edge.label).font(.system(size: 11 * zoom)).foregroundColor(color))
                let measured = text.measure(in: CGSize(width: 10_000, height: 100))
                for shift in [CGFloat(0), -22 * zoom, 22 * zoom, -44 * zoom, 44 * zoom] {
                    let rect = CGRect(x: middle.x - measured.width / 2 - 6,
                                      y: middle.y + shift - measured.height / 2 - 3,
                                      width: measured.width + 12, height: measured.height + 6)
                    guard CGRect(origin: .zero, size: size).contains(rect),
                          !occupied.contains(where: { $0.intersects(rect) }) else { continue }
                    occupied.append(rect.insetBy(dx: -3, dy: -3))
                    labels.append((rect, text))
                    break
                }
            }
        }
        for (rect, text) in labels {
            context.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(Color(nsColor: .windowBackgroundColor).opacity(0.95)))
            context.draw(text, at: CGPoint(x: rect.midX, y: rect.midY))
        }
    }

    private func inspector(_ node: ServiceGraphNode) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(node.name).font(.title2.bold())
                    Spacer()
                    Button("Close", systemImage: "xmark") { selected = nil }.help("Close the service inspector").labelStyle(.iconOnly)
                }
                if let service = project.lastResult?.services.first(where: { $0.id == node.id }) {
                    ServiceCard(project: project, service: service, environment: project.lastResult?.envRequirements.first { $0.serviceId == service.id })
                    Button("Logs", systemImage: "terminal") {
                        _ = appState.logs(project: project, service: service)
                        onLogs(service.id)
                    }.help("Logs")
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
                }.help("Show the connected service").buttonStyle(.plain)
            }
        }
    }
}
