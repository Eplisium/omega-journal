import Foundation
import Testing
@testable import OmegaJournal
@testable import OmegaJournalCore

@Suite("W1Int place stamps")
struct W1IntPlaceStampTests {
    @Test func roundTripsWithCoordinatesAndStaysReadableByTheEditorCodec() {
        let stamp = PlaceStamp(location: "Café; <Paris>", weather: "Sunny", coordinate: PlaceCoordinate(latitude: 48.856613, longitude: 2.352222))
        let body = PlaceStampCodec.join(stamp: stamp, rest: "Hello")
        #expect(body.hasSuffix("geo=48.85661,2.35222 -->"))
        #expect(!body.contains("<Paris>"))
        let (back, rest) = PlaceStampCodec.split(body)
        #expect(rest == "Hello")
        #expect(back?.location == "Café; <Paris>")
        #expect(back?.weather == "Sunny")
        #expect(back?.coordinate == PlaceCoordinate(latitude: 48.85661, longitude: 2.35222))
        let legacy = EntryStampCodec.split(body)
        #expect(legacy.stamp?.location == "Café; <Paris>")
        #expect(legacy.stamp?.weather == "Sunny")
    }

    @Test func invalidCoordinatesAreDropped() {
        #expect(!PlaceCoordinate(latitude: 0, longitude: 0).isValid)
        #expect(!PlaceCoordinate(latitude: 91, longitude: 0).isValid)
        #expect(!PlaceCoordinate(latitude: .nan, longitude: 1).isValid)
        #expect(PlaceStampCodec.split("x\n\n<!-- stamp: loc=A; geo=999,1 -->").stamp?.coordinate == nil)
        #expect(PlaceStampCodec.split("x\n\n<!-- stamp: geo=abc -->").stamp?.coordinate == nil)
        #expect(PlaceStampCodec.join(stamp: PlaceStamp(coordinate: PlaceCoordinate(latitude: 0, longitude: 0)), rest: "x") == "x")
    }

    @Test func settingPlaceKeepsWeather() {
        let body = "Notes\n\n<!-- stamp: loc=Old; wx=Rain -->"
        let out = PlaceStampCodec.settingPlace("New", coordinate: PlaceCoordinate(latitude: 1.5, longitude: 2.5), on: body)
        let s = PlaceStampCodec.split(out)
        #expect(s.rest == "Notes")
        #expect(s.stamp == PlaceStamp(location: "New", weather: "Rain", coordinate: PlaceCoordinate(latitude: 1.5, longitude: 2.5)))
        #expect(PlaceStampCodec.split("No stamp").stamp == nil)
        #expect(PlaceStampCodec.split("<!-- stamp: loc=A --> trailing text").stamp == nil)
    }
}

@Suite("W1Int map privacy and clustering")
struct W1IntPlaceIndexTests {
    static func body(_ name: String, _ lat: Double, _ lon: Double) -> String {
        PlaceStampCodec.join(stamp: PlaceStamp(location: name, coordinate: PlaceCoordinate(latitude: lat, longitude: lon)), rest: "text")
    }
    static let d0 = Date(timeIntervalSince1970: 1_700_000_000)
    static let entries = [
        PlaceSourceEntry(id: "a", title: "Louvre", body: body("Paris", 48.8606, 2.3376), createdAt: d0, isHidden: false),
        PlaceSourceEntry(id: "b", title: "", body: body("Paris", 48.8584, 2.2945), createdAt: d0.addingTimeInterval(60), isHidden: false),
        PlaceSourceEntry(id: "h", title: "Secret", body: body("Clinic", 51.5, -0.12), createdAt: d0, isHidden: true),
        PlaceSourceEntry(id: "t", title: "Trashed", body: body("Rome", 41.9, 12.5), createdAt: d0, isHidden: false, isTrashed: true),
        PlaceSourceEntry(id: "n", title: "Named", body: "x\n\n<!-- stamp: loc=Somewhere -->", createdAt: d0, isHidden: false),
        PlaceSourceEntry(id: "nh", title: "Named hidden", body: "x\n\n<!-- stamp: loc=Elsewhere -->", createdAt: d0, isHidden: true),
    ]

    @Test func lockedHiddenAndTrashedNeverBecomePins() {
        let locked = PlaceIndex.points(from: Self.entries, hiddenLocked: true)
        #expect(locked.map(\.entryId) == ["b", "a"])
        #expect(locked.first?.title == "Untitled")
        #expect(PlaceIndex.namedOnlyCount(in: Self.entries, hiddenLocked: true) == 1)
        let unlocked = PlaceIndex.points(from: Self.entries, hiddenLocked: false)
        #expect(Set(unlocked.map(\.entryId)) == ["a", "b", "h"])
        #expect(PlaceIndex.namedOnlyCount(in: Self.entries, hiddenLocked: false) == 2)
    }

    @Test func clustersMergeAtWideSpansAndSplitWhenZoomed() {
        let points = PlaceIndex.points(from: Self.entries, hiddenLocked: false)
        let wide = PlaceIndex.clusters(points, latitudeSpan: 60, longitudeSpan: 60)
        #expect(wide.map(\.count) == [2, 1])
        #expect(wide.first?.points.map(\.entryId) == ["b", "a"])
        let close = PlaceIndex.clusters(points, latitudeSpan: 0.05, longitudeSpan: 0.05)
        #expect(close.count == 3)
        // Order-independent.
        #expect(PlaceIndex.clusters(points.reversed(), latitudeSpan: 60, longitudeSpan: 60) == wide)
    }

    @Test func boundingRegionFitsAllPoints() throws {
        let points = PlaceIndex.points(from: Self.entries, hiddenLocked: true)
        let r = try #require(PlaceIndex.boundingRegion(points))
        #expect(abs(r.center.latitude - 48.8595) < 1e-9)
        #expect(r.lonSpan >= 2.3376 - 2.2945)
        #expect(PlaceIndex.boundingRegion([]) == nil)
        let one = try #require(PlaceIndex.boundingRegion([points[0]]))
        #expect(one.latSpan == 0.02 && one.lonSpan == 0.02)
    }

    @Test func pinActions() {
        let points = PlaceIndex.points(from: Self.entries, hiddenLocked: true)
        let single = PlaceIndex.clusters([points[0]], latitudeSpan: 1, longitudeSpan: 1)[0]
        #expect(PlaceIndex.action(for: single) == .open(entryId: "b"))
        let spread = PlaceIndex.clusters(points, latitudeSpan: 60, longitudeSpan: 60)[0]
        if case .zoom(_, let lat, let lon) = PlaceIndex.action(for: spread) {
            #expect(lon > 0.04 && lat >= 0.002)
        } else {
            Issue.record("expected zoom")
        }
        let same = [
            PlacePoint(entryId: "x", title: "X", date: Self.d0, placeName: "Home", coordinate: PlaceCoordinate(latitude: 10, longitude: 10)),
            PlacePoint(entryId: "y", title: "Y", date: Self.d0, placeName: "Home", coordinate: PlaceCoordinate(latitude: 10.0001, longitude: 10)),
        ]
        let stacked = PlaceIndex.clusters(same, latitudeSpan: 1, longitudeSpan: 1)[0]
        if case .list(let listed) = PlaceIndex.action(for: stacked) {
            #expect(Set(listed.map(\.entryId)) == ["x", "y"])
        } else {
            Issue.record("expected list")
        }
    }
}
