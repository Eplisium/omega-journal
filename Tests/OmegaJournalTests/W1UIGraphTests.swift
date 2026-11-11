import Foundation
import Testing
@testable import OmegaJournal
import OmegaJournalCore

@Suite("W1UI: graph layout performance and settling")
struct W1UIGraphLayoutTests {
    /// A deterministic sparse graph: a chain plus a few cross-links.
    static func layout(nodes n: Int, width: Double = 1200, height: Double = 900) -> GraphLayout {
        let ids = (0..<n).map { "n\($0)" }
        var links: [(String, String)] = []
        for i in 1..<max(1, n) { links.append((ids[i - 1], ids[i])) }
        for i in stride(from: 0, to: n, by: 7) where i + 13 < n { links.append((ids[i], ids[i + 13])) }
        return GraphLayout(nodeIDs: ids, links: links, width: width, height: height)
    }

    @Test("positions stay finite and inside the canvas, small and large")
    func bounded() {
        for n in [1, 2, 40, GraphLayout.exactRepulsionLimit + 50] {
            var l = Self.layout(nodes: n)
            for _ in 0..<30 { l.step() }
            #expect(l.positions.count == n)
            for p in l.positions.values {
                #expect(p.x.isFinite && p.y.isFinite)
                #expect(p.x >= 20 && p.x <= 1180 && p.y >= 20 && p.y <= 880)
            }
        }
    }

    @Test("a 2,000-node step stays within budget (Barnes–Hut, not n²)")
    func twoThousandNodeBudget() {
        var l = Self.layout(nodes: 2000)
        let clock = ContinuousClock()
        var worst = Duration.zero
        for _ in 0..<3 {
            let t = clock.measure { l.step() }
            worst = max(worst, t)
            // Deterministic budget: far below the 1,999,000 pairs of the old O(n²) step.
            #expect(l.lastStepInteractions < 2000 * 2000 / 2 / 8, "\(l.lastStepInteractions)")
        }
        // Generous wall-clock guard (debug build, shared CI runners).
        #expect(worst < .milliseconds(400), "\(worst)")
    }

    @Test("small graphs keep exact pairwise repulsion")
    func exactSmall() {
        var l = Self.layout(nodes: 40)
        l.step()
        #expect(l.lastStepInteractions == 40 * 39 / 2)
    }

    @Test("layout is deterministic")
    func deterministic() {
        var a = Self.layout(nodes: 500), b = Self.layout(nodes: 500)
        for _ in 0..<10 { a.step(); b.step() }
        #expect(a.xs == b.xs && a.ys == b.ys)
    }

    @Test("a graph settles: energy falls under the threshold")
    func settles() {
        var l = Self.layout(nodes: 30, width: 800, height: 600)
        var settled = false
        for frame in 0..<GraphSimulation.maxFrames {
            let alpha = max(0.1, 1 - Double(frame) / 240)
            if l.isSettled(energy: l.step(alpha: alpha)) { settled = true; break }
        }
        #expect(settled)
    }

    @Test("move pins a node by id; unknown ids are ignored")
    func move() {
        var l = Self.layout(nodes: 5)
        l.move("n2", to: GraphPoint(x: 100, y: 120))
        #expect(l.position(of: "n2") == GraphPoint(x: 100, y: 120))
        l.move("missing", to: GraphPoint(x: 1, y: 1))
        #expect(l.position(of: "missing") == nil)
    }
}

@Suite("W1UI: graph simulation frame loop")
@MainActor
struct W1UIGraphSimulationTests {
    static func graph(_ n: Int) -> LinkGraph {
        let entries = (0..<n).map { i in
            LinkableEntry(id: "e\(i)", title: "Note \(i)", body: i + 1 < n ? "See [[Note \(i + 1)]]" : "", isHidden: false)
        }
        return LinkGraph.build(entries: entries)
    }

    @Test("the frame loop stops by itself once the layout settles")
    func stopsWhenSettled() async throws {
        let sim = GraphSimulation(graph: Self.graph(6), size: CGSize(width: 600, height: 400),
                                  settleImmediately: false, frameInterval: .zero)
        sim.start()
        #expect(sim.isRunning)
        for _ in 0..<2000 where sim.isRunning { await Task.yield() }
        #expect(!sim.isRunning)
        #expect(sim.isSettled)
        #expect(sim.frames <= GraphSimulation.maxFrames + 1)
        let tick = sim.tick
        sim.advance(dragging: false)
        #expect(sim.tick == tick, "a settled layout does no work")
    }

    @Test("dragging or moving a node wakes the loop")
    func wakes() async throws {
        let sim = GraphSimulation(graph: Self.graph(6), size: CGSize(width: 600, height: 400),
                                  settleImmediately: false, frameInterval: .zero)
        sim.start()
        for _ in 0..<2000 where sim.isRunning { await Task.yield() }
        #expect(!sim.isRunning)
        sim.move("e0", to: CGPoint(x: 50, y: 50))
        #expect(sim.isRunning)
        #expect(!sim.isSettled)
        sim.stop()
        #expect(!sim.isRunning)
    }

    @Test("reduce motion: settled up front, never animates")
    func reduceMotion() {
        let sim = GraphSimulation(graph: Self.graph(6), size: CGSize(width: 600, height: 400),
                                  settleImmediately: true)
        #expect(sim.isSettled)
        sim.start()
        #expect(!sim.isRunning)
        sim.move("e1", to: CGPoint(x: 80, y: 80))
        #expect(!sim.isRunning)
        #expect(sim.position(of: "e1") == CGPoint(x: 80, y: 80))
    }
}
