import SwiftUI
import OmegaJournalCore

// MARK: - Link graph (interactive, force-directed)

/// Holds the simulation so the Canvas redraws as it settles. It runs its own
/// frame loop only while the layout is moving — once the energy drops below
/// the settle threshold the loop ends, and a drag, resize or rebuild wakes it.
/// Reduce Motion → the layout is settled up front and never animates.
@MainActor
@Observable
final class GraphSimulation {
    private(set) var tick = 0
    /// True while the frame loop is running (observable for tests / UI).
    private(set) var isRunning = false
    // Only `tick` drives redraws; the simulation state below changes on every
    // frame and is read through `tick`.
    @ObservationIgnored private(set) var layout: GraphLayout
    @ObservationIgnored private(set) var graph: LinkGraph
    @ObservationIgnored private(set) var isSettled = false
    @ObservationIgnored private(set) var frames = 0
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private let animates: Bool
    @ObservationIgnored private let frameInterval: Duration
    /// While a node is held the layout keeps responding even if settled.
    @ObservationIgnored var isDragging = false {
        didSet { if isDragging { wake() } }
    }

    /// Hard stop: a layout that never calms (huge graphs) stops after this many frames.
    static let maxFrames = 600

    init(graph: LinkGraph, size: CGSize, settleImmediately: Bool, frameInterval: Duration = .milliseconds(33)) {
        self.graph = graph
        self.frameInterval = frameInterval
        animates = !settleImmediately
        layout = GraphLayout(graph: graph, width: max(200, Double(size.width)), height: max(200, Double(size.height)))
        if settleImmediately { layout.settle(); isSettled = true }
    }

    func resize(_ size: CGSize) {
        guard size.width > 50, size.height > 50 else { return }
        if abs(layout.width - Double(size.width)) > 1 || abs(layout.height - Double(size.height)) > 1 {
            layout.width = Double(size.width); layout.height = Double(size.height)
            if animates { wake() } else { layout.settle(); tick &+= 1 }
        }
    }

    /// Marks the layout as moving and (when animating) starts the frame loop.
    func wake() {
        isSettled = false; frames = 0
        start()
    }

    /// Starts the frame loop if the layout is still moving.
    func start() {
        guard animates, loop == nil, !isSettled || isDragging else { return }
        isRunning = true
        loop = Task { @MainActor [weak self, frameInterval] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.isSettled && !self.isDragging { break }
                self.advance(dragging: self.isDragging)
                try? await Task.sleep(for: frameInterval)
            }
            self?.loop = nil
            self?.isRunning = false
        }
    }

    /// Stops the frame loop (view gone).
    func stop() {
        loop?.cancel(); loop = nil
        isRunning = false
    }

    func advance(dragging: Bool) {
        guard !isSettled || dragging else { return }
        let alpha = max(0.1, 1 - Double(frames) / 240)
        let energy = layout.step(alpha: alpha)
        frames += 1
        if !dragging && (layout.isSettled(energy: energy) || frames > Self.maxFrames) { isSettled = true }
        tick &+= 1
    }

    func move(_ id: String, to p: CGPoint) {
        layout.move(id, to: GraphPoint(x: Double(p.x), y: Double(p.y)))
        if animates { wake() }
        tick &+= 1
    }

    func position(of id: String) -> CGPoint? {
        layout.position(of: id).map { CGPoint(x: $0.x, y: $0.y) }
    }

    func node(at point: CGPoint, radius: CGFloat = 16) -> LinkGraph.Node? {
        var best: (LinkGraph.Node, CGFloat)?
        for n in graph.nodes {
            guard let p = position(of: n.id) else { continue }
            let d = hypot(p.x - point.x, p.y - point.y)
            if d <= radius, best.map({ d < $0.1 }) ?? true { best = (n, d) }
        }
        return best?.0
    }
}

struct GraphView: View {
    var vm: JournalViewModel
    var onOpen: (JournalEntry) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let theme = ThemeManager.shared
    private let biometric = BiometricAuth.shared

    @State private var sim: GraphSimulation?
    @State private var includeIsolated = false
    @State private var hoveredId: String?
    @State private var draggingId: String?
    @State private var dragMoved = false
    @State private var canvasSize = CGSize(width: 800, height: 560)

    private func rebuild() {
        sim?.stop()
        let graph = vm.linkGraph(includeIsolated: includeIsolated)
        let next = GraphSimulation(graph: graph, size: canvasSize, settleImmediately: reduceMotion)
        sim = next
        next.start()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: OmegaTheme.Spacing.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Graph").font(OmegaTheme.font(.heading, .semibold, design: .serif)).foregroundColor(theme.titleTextColor)
                    Text(summary).font(OmegaTheme.font(.meta)).foregroundColor(theme.secondaryTextColor)
                }
                Spacer()
                Toggle("Show unlinked notes", isOn: $includeIsolated)
                    .toggleStyle(.switch).controlSize(.small)
                    .font(OmegaTheme.font(.meta))
                    .onChange(of: includeIsolated) { _, _ in rebuild() }
                OmegaIconButton(systemImage: "xmark", accessibilityLabel: "Close graph", size: .body) { dismiss() }
            }
            .padding(OmegaTheme.Spacing.l)
            Divider().opacity(0.25)

            if let sim, !sim.graph.nodes.isEmpty {
                GeometryReader { geo in
                    graphCanvas(sim)
                        .onAppear { canvasSize = geo.size; sim.resize(geo.size) }
                        .onChange(of: geo.size) { _, s in canvasSize = s; sim.resize(s) }
                }
            } else {
                OmegaEmptyState(systemImage: "point.3.connected.trianglepath.dotted",
                                title: "No links yet",
                                message: "Link entries with [[Entry title]] while writing and they'll appear here as a map of your thinking.")
            }
        }
        .frame(minWidth: 720, minHeight: 540)
        .background(theme.backgroundColor)
        .onAppear { if sim == nil { rebuild() } }
        .onChange(of: biometric.isAuthenticated) { _, _ in rebuild() }   // lock → hidden nodes vanish immediately
        .onDisappear { sim?.stop() }
        .onChange(of: reduceMotion) { _, _ in rebuild() }
    }

    private var summary: String {
        guard let sim else { return "" }
        return "\(sim.graph.nodes.count) notes · \(sim.graph.edges.count) links"
    }

    private func graphCanvas(_ sim: GraphSimulation) -> some View {
        let _ = sim.tick
        let focus = hoveredId ?? draggingId
        let near = focus.map { sim.graph.neighbours(of: $0) } ?? []
        return Canvas { ctx, _ in
            for e in sim.graph.edges {
                guard let a = sim.position(of: e.from), let b = sim.position(of: e.to) else { continue }
                var path = Path(); path.move(to: a); path.addLine(to: b)
                let emphasised = focus != nil && (e.from == focus || e.to == focus)
                ctx.stroke(path, with: .color(emphasised ? theme.accentColor.opacity(0.85) : theme.secondaryTextColor.opacity(focus == nil ? 0.35 : 0.12)),
                           lineWidth: emphasised ? 1.8 : 1)
            }
            for n in sim.graph.nodes {
                guard let p = sim.position(of: n.id) else { continue }
                let r = 5 + min(9, CGFloat(n.degree) * 1.6)
                let dim = focus != nil && n.id != focus && !near.contains(n.id)
                let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
                let selected = n.id == vm.selectedEntryId
                ctx.fill(Path(ellipseIn: rect), with: .color(theme.accentColor.opacity(dim ? 0.25 : 0.9)))
                if selected { ctx.stroke(Path(ellipseIn: rect.insetBy(dx: -3, dy: -3)), with: .color(theme.titleTextColor), lineWidth: 1.5) }
                if n.id == focus || n.degree >= 3 || sim.graph.nodes.count <= 14 {
                    let label = Text(n.title).font(OmegaTheme.font(.meta, n.id == focus ? .semibold : .regular))
                        .foregroundColor(theme.titleTextColor.opacity(dim ? 0.3 : 1))
                    ctx.draw(label, at: CGPoint(x: p.x, y: p.y + r + 9), anchor: .center)
                }
            }
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let p): hoveredId = sim.node(at: p)?.id
            case .ended: hoveredId = nil
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if draggingId == nil {
                        draggingId = sim.node(at: value.startLocation)?.id; dragMoved = false
                        sim.isDragging = draggingId != nil && !reduceMotion
                    }
                    guard let id = draggingId else { return }
                    if hypot(value.translation.width, value.translation.height) > 3 { dragMoved = true }
                    if dragMoved || reduceMotion { sim.move(id, to: value.location) }
                }
                .onEnded { _ in
                    if let id = draggingId, !dragMoved, let e = vm.entry(id: id) { onOpen(e); dismiss() }
                    draggingId = nil
                    sim.isDragging = false
                }
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Entry link graph, \(summary)")
        .overlay(alignment: .bottomLeading) {
            // Keyboard / VoiceOver route to the same data: a plain list of connected notes.
            Menu {
                ForEach(sim.graph.nodes.sorted { $0.degree > $1.degree }) { n in
                    Button("\(n.title) (\(n.degree))") { if let e = vm.entry(id: n.id) { onOpen(e); dismiss() } }
                }
            } label: { Label("Open note…", systemImage: "list.bullet") }
            .menuStyle(.borderlessButton).fixedSize()
            .padding(OmegaTheme.Spacing.m)
            .accessibilityLabel("Open a note from the graph")
        }
    }
}
