import SwiftUI
import SwiftData

struct GraphView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Idea.createdAt, order: .reverse) private var ideas: [Idea]
    @State private var selectedIdea: Idea?
    @State private var dragOffsets: [PersistentIdentifier: CGSize] = [:]
    @State private var scale: CGFloat = 1.0
    @State private var baseScale: CGFloat = 1.0
    @State private var panOffset: CGSize = .zero
    @State private var lastPanOffset: CGSize = .zero
    @State private var didLayout = false
    @State private var nodeSizes: [PersistentIdentifier: CGSize] = [:]

    var body: some View {
        GeometryReader { geo in
            canvas(geo: geo)
                .onAppear {
                    if !didLayout {
                        spreadNodes(canvasSize: geo.size)
                        didLayout = true
                    }
                }
        }
        .background(Color.bgBase)
    }

    // MARK: - Canvas

    @ViewBuilder
    private func canvas(geo: GeometryProxy) -> some View {
        let canvasCenter = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)

        ZStack {
            // Background — captures pan gesture on empty space only
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { value in
                            panOffset = CGSize(
                                width: lastPanOffset.width + value.translation.width,
                                height: lastPanOffset.height + value.translation.height
                            )
                        }
                        .onEnded { _ in
                            lastPanOffset = panOffset
                        }
                )

            // Connection lines
            ForEach(ideas) { idea in
                ForEach(idea.linkedTo) { linked in
                    let fromCenter = worldToScreen(worldPos: nodePosition(for: idea), canvasCenter: canvasCenter)
                    let toCenter = worldToScreen(worldPos: nodePosition(for: linked), canvasCenter: canvasCenter)
                    let fromSize = nodeSizes[idea.persistentModelID] ?? CGSize(width: 160, height: 60)
                    let toSize = nodeSizes[linked.persistentModelID] ?? CGSize(width: 160, height: 60)
                    let fromEdge = edgePoint(center: fromCenter, nodeSize: fromSize, towards: toCenter)
                    let toEdge = edgePoint(center: toCenter, nodeSize: toSize, towards: fromCenter)
                    let isHighlighted = selectedIdea?.persistentModelID == idea.persistentModelID
                        || selectedIdea?.persistentModelID == linked.persistentModelID

                    ConnectionLine(from: fromEdge, to: toEdge, isHighlighted: isHighlighted)
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            }

            // Nodes
            ForEach(ideas) { idea in
                let isSelected = selectedIdea?.persistentModelID == idea.persistentModelID
                let isConnectedToSelected = selectedIdea?.allLinks.contains(where: {
                    $0.persistentModelID == idea.persistentModelID
                }) ?? false
                let screenPos = worldToScreen(worldPos: nodePosition(for: idea), canvasCenter: canvasCenter)

                NodeView(idea: idea, isSelected: isSelected || isConnectedToSelected)
                    .background(
                        GeometryReader { nodeGeo in
                            Color.clear
                                .onAppear {
                                    nodeSizes[idea.persistentModelID] = nodeGeo.size
                                }
                                .onChange(of: nodeGeo.size) { _, newSize in
                                    nodeSizes[idea.persistentModelID] = newSize
                                }
                        }
                    )
                    .scaleEffect(scale)
                    .position(screenPos)
                    .gesture(
                        DragGesture(minimumDistance: 4)
                            .onChanged { value in
                                dragOffsets[idea.persistentModelID] = value.translation
                            }
                            .onEnded { value in
                                idea.positionX += Double(value.translation.width / scale)
                                idea.positionY += Double(value.translation.height / scale)
                                dragOffsets[idea.persistentModelID] = nil
                                try? modelContext.save()
                            }
                    )
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.2)) {
                            if selectedIdea?.persistentModelID == idea.persistentModelID {
                                selectedIdea = nil
                            } else {
                                selectedIdea = idea
                            }
                        }
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    let newScale = baseScale * value.magnification
                    scale = max(0.15, min(4.0, newScale))
                }
                .onEnded { _ in
                    baseScale = scale
                }
        )
        #if os(macOS)
        .onScrollWheel { delta in
            let zoomSpeed: CGFloat = 0.01
            let newScale = scale + delta.y * zoomSpeed * scale
            scale = max(0.15, min(4.0, newScale))
            baseScale = scale
        }
        #endif
        .clipped()
    }

    // MARK: - Coordinate Transform

    /// Convert world coordinates to screen coordinates
    private func worldToScreen(worldPos: CGPoint, canvasCenter: CGPoint) -> CGPoint {
        CGPoint(
            x: canvasCenter.x + (worldPos.x * scale) + panOffset.width,
            y: canvasCenter.y + (worldPos.y * scale) + panOffset.height
        )
    }

    /// Find the point on the edge of a node's rect closest to a target point
    private func edgePoint(center: CGPoint, nodeSize: CGSize, towards target: CGPoint) -> CGPoint {
        let halfW = (nodeSize.width / 2) * scale
        let halfH = (nodeSize.height / 2) * scale

        let dx = target.x - center.x
        let dy = target.y - center.y

        guard abs(dx) > 0.1 || abs(dy) > 0.1 else { return center }

        // How far along the center→target vector to reach each edge
        let tX = halfW / max(abs(dx), 0.01)
        let tY = halfH / max(abs(dy), 0.01)
        let t = min(tX, tY)

        return CGPoint(
            x: center.x + dx * t,
            y: center.y + dy * t
        )
    }

    private func nodePosition(for idea: Idea) -> CGPoint {
        let drag = dragOffsets[idea.persistentModelID] ?? .zero
        return CGPoint(
            x: idea.positionX + Double(drag.width / scale),
            y: idea.positionY + Double(drag.height / scale)
        )
    }

    // MARK: - Layout

    private func spreadNodes(canvasSize: CGSize) {
        let count = ideas.count
        guard count > 0 else { return }

        let needsLayout = ideas.allSatisfy { $0.positionX == 0 && $0.positionY == 0 }
            || areTooClose()
        guard needsLayout else { return }

        if count == 1 {
            ideas[0].positionX = 0
            ideas[0].positionY = 0
            return
        }

        // Arrange in circle centered at origin
        let radius = max(200.0, Double(count) * 70.0)
        for (i, idea) in ideas.enumerated() {
            let angle = (2.0 * Double.pi * Double(i)) / Double(count) - Double.pi / 2
            idea.positionX = radius * cos(angle)
            idea.positionY = radius * sin(angle)
        }

        try? modelContext.save()
    }

    private func areTooClose() -> Bool {
        guard ideas.count > 1 else { return false }
        let minDistance: Double = 200
        for i in 0..<ideas.count {
            for j in (i + 1)..<ideas.count {
                let dx = ideas[i].positionX - ideas[j].positionX
                let dy = ideas[i].positionY - ideas[j].positionY
                if sqrt(dx * dx + dy * dy) < minDistance { return true }
            }
        }
        return false
    }
}

#if os(macOS)
// MARK: - Scroll Wheel Modifier (macOS trackpad zoom)

struct ScrollWheelModifier: ViewModifier {
    let handler: (CGPoint) -> Void

    func body(content: Content) -> some View {
        content.overlay {
            ScrollWheelView(handler: handler)
                .allowsHitTesting(false)
        }
    }
}

struct ScrollWheelView: NSViewRepresentable {
    let handler: (CGPoint) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(handler: handler)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        let coordinator = context.coordinator
        coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak view] event in
            guard let view = view, view.window != nil else { return event }
            let locationInView = view.convert(event.locationInWindow, from: nil)
            if view.bounds.contains(locationInView) {
                coordinator.handler(CGPoint(x: Double(event.scrollingDeltaX), y: Double(event.scrollingDeltaY)))
            }
            return event
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.handler = handler
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    class Coordinator {
        var handler: (CGPoint) -> Void
        var monitor: Any?

        init(handler: @escaping (CGPoint) -> Void) {
            self.handler = handler
        }

        func removeMonitor() {
            if let monitor = monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }
}

extension View {
    func onScrollWheel(handler: @escaping (CGPoint) -> Void) -> some View {
        modifier(ScrollWheelModifier(handler: handler))
    }
}
#endif

// MARK: - Connection Line

struct ConnectionLine: View {
    let from: CGPoint
    let to: CGPoint
    let isHighlighted: Bool

    var body: some View {
        Canvas { context, size in
            var path = Path()
            path.move(to: from)

            // Curved bezier
            let midX = (from.x + to.x) / 2
            let midY = (from.y + to.y) / 2
            let dx = to.x - from.x
            let dy = to.y - from.y
            let controlOffset = min(abs(dx), abs(dy)) * 0.25
            let controlPoint = CGPoint(
                x: midX + (dy > 0 ? controlOffset : -controlOffset),
                y: midY + (dx > 0 ? -controlOffset : controlOffset)
            )
            path.addQuadCurve(to: to, control: controlPoint)

            context.stroke(
                path,
                with: .color(Color.fg.opacity(isHighlighted ? 0.5 : 0.15)),
                lineWidth: isHighlighted ? 2 : 1
            )
        }
        .allowsHitTesting(false)
    }
}

#Preview {
    GraphView()
        .modelContainer(for: [Idea.self, UserProfile.self], inMemory: true)
        .frame(width: 600, height: 800)
}
