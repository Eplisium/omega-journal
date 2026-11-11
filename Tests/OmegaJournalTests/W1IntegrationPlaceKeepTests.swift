import Foundation
import Testing
@testable import OmegaJournalCore

/// The editor reads and writes the trailing stamp with `EntryStampCodec`.
/// Map coordinates (`geo=`) must survive that round trip, or every editor
/// save would silently drop a place from the map.
@Suite("W1 integration: editor stamp keeps map coordinates")
struct W1IntegrationPlaceKeepTests {
    static let body = PlaceStampCodec.join(
        stamp: PlaceStamp(location: "Hyde Park", weather: "Sunny",
                          coordinate: PlaceCoordinate(latitude: 51.50735, longitude: -0.16572)),
        rest: "Walked by the lake.")

    @Test("split → join keeps geo= verbatim")
    func roundTripKeepsGeo() throws {
        let parts = EntryStampCodec.split(Self.body)
        let stamp = try #require(parts.stamp)
        #expect(stamp.geo == "51.50735,-0.16572")
        #expect(stamp.location == "Hyde Park" && stamp.weather == "Sunny")
        let resaved = EntryStampCodec.join(stamp: stamp, rest: parts.rest + " Then home.")
        #expect(PlaceStampCodec.split(resaved).stamp?.coordinate
                == PlaceCoordinate(latitude: 51.50735, longitude: -0.16572))
        #expect(PlaceStampCodec.split(resaved).rest == "Walked by the lake. Then home.")
    }

    @Test("a geo-only stamp is not empty and survives")
    func geoOnly() throws {
        let body = "x\n\n<!-- stamp: geo=1.5,2.5 -->"
        let stamp = try #require(EntryStampCodec.split(body).stamp)
        #expect(!stamp.isEmpty)
        #expect(EntryStampCodec.join(stamp: stamp, rest: "x") == body)
    }

    @Test("join writes only coordinate characters")
    func sanitized() {
        let out = EntryStampCodec.join(stamp: EntryStamp(location: "A", geo: "1.5, 2.5<script>;wx=x"), rest: "x")
        #expect(out == "x\n\n<!-- stamp: loc=A; geo=1.5,2.5 -->")
    }

    @Test("editing the place name drops the old coordinates; keeping it does not")
    func editingLocationClearsGeo() throws {
        var stamp = try #require(EntryStampCodec.split(Self.body).stamp)
        stamp.editLocation("Hyde Park")
        #expect(stamp.geo == "51.50735,-0.16572")
        stamp.editLocation("Regent's Park")
        #expect(stamp.geo.isEmpty)
        #expect(stamp.weather == "Sunny")
        let resaved = EntryStampCodec.join(stamp: stamp, rest: "Walked.")
        #expect(PlaceStampCodec.split(resaved).stamp?.coordinate == nil)
        #expect(PlaceStampCodec.split(resaved).stamp?.location == "Regent's Park")
    }
}
