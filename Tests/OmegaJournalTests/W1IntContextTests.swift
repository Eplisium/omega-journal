import Foundation
import Testing
@testable import OmegaJournal
@testable import OmegaJournalCore

// Fakes stand in for CoreLocation/EventKit/PhotoKit: no real permission prompts.
final class W1IntFakePlace: ContextPlaceProviding {
    var status: ContextAccess
    var grantOnRequest: Bool
    var result: Result<ContextPlace, Error>
    private(set) var requests = 0
    private(set) var fetches = 0
    init(status: ContextAccess = .notDetermined, grantOnRequest: Bool = true,
         result: Result<ContextPlace, Error> = .success(ContextPlace(name: "Hyde Park, London",
                                                                      coordinate: PlaceCoordinate(latitude: 51.5073, longitude: -0.1657)))) {
        self.status = status; self.grantOnRequest = grantOnRequest; self.result = result
    }
    func access() -> ContextAccess { status }
    func requestAccess() async -> Bool { requests += 1; status = grantOnRequest ? .granted : .denied; return grantOnRequest }
    func currentPlace() async throws -> ContextPlace { fetches += 1; return try result.get() }
}

final class W1IntFakeCalendar: ContextCalendarProviding {
    var status: ContextAccess
    var events: [ContextEvent]
    private(set) var requests = 0
    private(set) var asked: (Date, Date)?
    init(status: ContextAccess = .notDetermined, events: [ContextEvent] = []) { self.status = status; self.events = events }
    func access() -> ContextAccess { status }
    func requestAccess() async -> Bool { requests += 1; status = .granted; return true }
    func events(from start: Date, to end: Date) async throws -> [ContextEvent] { asked = (start, end); return events }
}

final class W1IntFakePhotos: ContextPhotosProviding {
    var status: ContextAccess
    private(set) var requests = 0
    private(set) var fileRequests: [String] = []
    init(status: ContextAccess = .notDetermined) { self.status = status }
    func access() -> ContextAccess { status }
    func requestAccess() async -> Bool { requests += 1; status = .granted; return true }
    func photos(from start: Date, to end: Date, limit: Int) async -> [ContextPhoto] {
        (0..<min(limit, 3)).map { ContextPhoto(id: "p\($0)", created: start.addingTimeInterval(Double($0) * 60), thumbnail: nil) }
    }
    func file(for id: String) async -> ContextPhotoFile? {
        fileRequests.append(id)
        return id == "missing" ? nil : ContextPhotoFile(data: Data([0xFF, 0xD8, 0xFF]), filename: "\(id).jpg", mimeType: "image/jpeg")
    }
}

@Suite("W1Int context rules")
struct W1IntContextFormattingTests {
    static var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    @Test func policyIsOptInAndPhotosNeedAnExplicitPick() {
        #expect(ContextPolicy.sources(for: .explicit, enabled: [], autoOnNewEntry: true).isEmpty)
        #expect(ContextPolicy.sources(for: .explicit, enabled: .all, autoOnNewEntry: false) == .all)
        #expect(ContextPolicy.sources(for: .newEntry, enabled: .all, autoOnNewEntry: false).isEmpty)
        #expect(ContextPolicy.sources(for: .newEntry, enabled: .all, autoOnNewEntry: true) == [.place, .calendar])
        #expect(ContextPolicy.sources(for: .newEntry, enabled: [.photos], autoOnNewEntry: true).isEmpty)
    }

    @Test func placeLabels() {
        #expect(ContextFormatting.placeLabel(name: "Blue Bottle Coffee", locality: "Oakland", area: "CA", country: "US") == "Blue Bottle Coffee, Oakland")
        #expect(ContextFormatting.placeLabel(name: "Oakland, CA", locality: "Oakland", area: "CA", country: nil) == "Oakland, CA")
        #expect(ContextFormatting.placeLabel(name: nil, locality: " Paris ", area: "Île-de-France", country: nil) == "Paris, Île-de-France")
        #expect(ContextFormatting.placeLabel(name: "  ", locality: nil, area: nil, country: nil) == nil)
    }

    @Test func eventsBecomeASafeSortedList() {
        let base = Date(timeIntervalSince1970: 1_765_800_000) // 12:00 UTC
        let events = [
            ContextEvent(title: "Lunch with Sam", start: base, end: base.addingTimeInterval(3_600), isAllDay: false),
            ContextEvent(title: "# Standup <!-- x -->", start: base.addingTimeInterval(-10_800), end: base.addingTimeInterval(-9_900), isAllDay: false),
            ContextEvent(title: "Mum's birthday", start: base, end: base, isAllDay: true),
            ContextEvent(title: "  ", start: base.addingTimeInterval(3_600), end: base.addingTimeInterval(3_600), isAllDay: false),
        ]
        let md = ContextFormatting.eventsMarkdown(events, timeZone: TimeZone(identifier: "UTC")!, locale: Locale(identifier: "en_GB"))
        #expect(md == """
        **Today's calendar**
        - All day · Mum's birthday
        - 09:00 – 09:15 · \\# Standup ‹!-- x --›
        - 12:00 – 13:00 · Lunch with Sam
        - 13:00 · Untitled event
        """)
        #expect(ContextFormatting.eventsMarkdown([]) == nil)
        let many = (0..<15).map { ContextEvent(title: "E\($0)", start: base.addingTimeInterval(Double($0) * 60), end: base, isAllDay: false) }
        #expect(ContextFormatting.eventsMarkdown(many)?.hasSuffix("- and 3 more") == true)
    }

    @Test func eventsGoBeforeTheStampAndOnlyOnce() {
        let body = PlaceStampCodec.join(stamp: PlaceStamp(location: "Paris"), rest: "Notes")
        let block = "**Today's calendar**\n- All day · Holiday"
        let once = ContextFormatting.insertingEvents(block, into: body)
        #expect(PlaceStampCodec.split(once).rest == "Notes\n\n" + block)
        #expect(PlaceStampCodec.split(once).stamp?.location == "Paris")
        #expect(ContextFormatting.insertingEvents(block, into: once) == once)
        #expect(ContextFormatting.insertingEvents(block, into: "") == block)
    }

    @Test func dayIntervalAndPhotoNames() {
        let noon = Date(timeIntervalSince1970: 1_765_800_000)
        let (s, e) = ContextFormatting.dayInterval(noon, calendar: Self.utc)
        #expect(s == Date(timeIntervalSince1970: 1_765_756_800))
        #expect(e.timeIntervalSince(s) == 86_400)
        #expect(ContextFormatting.photoFilename(created: noon, uniformTypeExtension: "HEIC", timeZone: TimeZone(identifier: "UTC")!)
                == "Photo 2025-12-15 at 12.00.00.heic")
        #expect(ContextFormatting.photoFilename(created: nil, uniformTypeExtension: "../x") == "Photo from library.x")
    }
}

@Suite("W1Int context service")
@MainActor
struct W1IntContextServiceTests {
    private func defaults() -> UserDefaults {
        let name = "w1int.context.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func everySourceStartsOff() {
        let s = ContextSettings(defaults: defaults())
        #expect(s.enabled.isEmpty)
        #expect(!s.autoOnNewEntry)
    }

    @Test func gatheringWithNothingEnabledTouchesNoFramework() async {
        let place = W1IntFakePlace(status: .granted), cal = W1IntFakeCalendar(status: .granted), photos = W1IntFakePhotos(status: .granted)
        let svc = ContextService(settings: ContextSettings(defaults: defaults()), place: place, calendar: cal, photos: photos)
        let snap = await svc.gather(.explicit)
        #expect(snap.isEmpty && snap.problems.isEmpty)
        #expect(place.fetches == 0 && cal.asked == nil)
    }

    @Test func enablingAsksOnceAndRefusalLeavesItOff() async {
        let settings = ContextSettings(defaults: defaults())
        let place = W1IntFakePlace(grantOnRequest: false)
        let cal = W1IntFakeCalendar()
        let svc = ContextService(settings: settings, place: place, calendar: cal, photos: W1IntFakePhotos())
        #expect(await svc.enable(.place) == false)
        #expect(!settings.enabled.contains(.place))
        #expect(await svc.enable(.place) == false)
        #expect(place.requests == 1) // denied: never re-prompted
        #expect(await svc.enable(.calendar))
        #expect(settings.enabled == [.calendar])
        #expect(svc.enabled == [.calendar])
        svc.autoOnNewEntry = true
        #expect(settings.autoOnNewEntry)
        svc.disable(.calendar)
        #expect(settings.enabled.isEmpty)
        #expect(svc.enabled.isEmpty)
    }

    @Test func gatherFetchesOnlyEnabledSourcesForTheDay() async {
        let settings = ContextSettings(defaults: defaults())
        let base = Date(timeIntervalSince1970: 1_765_800_000)
        let cal = W1IntFakeCalendar(status: .granted, events: [ContextEvent(title: "Gym", start: base, end: base.addingTimeInterval(3_600), isAllDay: false)])
        let place = W1IntFakePlace(status: .granted)
        let svc = ContextService(settings: settings, place: place, calendar: cal, photos: W1IntFakePhotos(status: .granted))
        settings.set([.place, .calendar], true)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let snap = await svc.gather(.explicit, day: base, cal: utc)
        #expect(snap.place?.name == "Hyde Park, London")
        #expect(snap.events.map(\.title) == ["Gym"])
        #expect(snap.photos.isEmpty)
        #expect(cal.asked?.0 == Date(timeIntervalSince1970: 1_765_756_800))

        // New entry: nothing unless auto is on; photos never.
        settings.set(.photos, true)
        #expect(await svc.gather(.newEntry).isEmpty)
        settings.setAutoOnNewEntry(true)
        let auto = await svc.gather(.newEntry, day: base, cal: utc)
        #expect(auto.place != nil && !auto.events.isEmpty && auto.photos.isEmpty)
        #expect(!svc.isWorking)
    }

    @Test func revokedPermissionReportsInsteadOfPrompting() async {
        let settings = ContextSettings(defaults: defaults())
        settings.set(.all, true)
        let place = W1IntFakePlace(status: .denied)
        let photos = W1IntFakePhotos(status: .denied)
        let svc = ContextService(settings: settings, place: place, calendar: W1IntFakeCalendar(status: .denied), photos: photos)
        let snap = await svc.gather(.explicit)
        #expect(snap.isEmpty)
        #expect(snap.problems.count == 3)
        #expect(snap.problems[0].contains("System Settings › Privacy & Security › Location"))
        #expect(place.requests == 0 && photos.requests == 0)
    }

    @Test func placeFailureOnlyEmptiesThePlace() async {
        let settings = ContextSettings(defaults: defaults())
        settings.set([.place, .photos], true)
        let svc = ContextService(settings: settings,
                                 place: W1IntFakePlace(status: .granted, result: .failure(ContextError.unavailable("x"))),
                                 calendar: W1IntFakeCalendar(), photos: W1IntFakePhotos(status: .granted))
        let snap = await svc.gather(.explicit)
        #expect(snap.place == nil)
        #expect(snap.photos.count == 3)
        #expect(snap.problems == ["Couldn't find your location right now."])
    }

    @Test func pickedPhotosAreLoadedOnDemand() async {
        let photos = W1IntFakePhotos(status: .granted)
        let svc = ContextService(settings: ContextSettings(defaults: defaults()), place: W1IntFakePlace(),
                                 calendar: W1IntFakeCalendar(), photos: photos)
        let files = await svc.files(for: [ContextPhoto(id: "p1", created: nil), ContextPhoto(id: "missing", created: nil)])
        #expect(files.map(\.filename) == ["p1.jpg"])
        #expect(photos.fileRequests == ["p1", "missing"])
    }

    @Test func applyWritesPlaceStampAndEvents() {
        var snap = ContextSnapshot()
        snap.place = ContextPlace(name: "Hyde Park", coordinate: PlaceCoordinate(latitude: 51.5, longitude: -0.16))
        let base = Date(timeIntervalSince1970: 1_765_800_000)
        snap.events = [ContextEvent(title: "Holiday", start: base, end: base, isAllDay: true)]
        let out = ContextService.apply(snap, to: "Morning pages")
        let (stamp, rest) = PlaceStampCodec.split(out)
        #expect(rest == "Morning pages\n\n**Today's calendar**\n- All day · Holiday")
        #expect(stamp?.location == "Hyde Park")
        #expect(stamp?.coordinate == PlaceCoordinate(latitude: 51.5, longitude: -0.16))
        #expect(EntryStampCodec.split(out).stamp?.location == "Hyde Park")
        #expect(ContextService.apply(snap, to: "x", includePlace: false, includeEvents: false) == "x")
    }

    @Test func coordinateFallbackLabel() {
        #expect(LiveContextPlace.coordinateLabel(PlaceCoordinate(latitude: 51.50731, longitude: -0.16571)) == "51.507, -0.166")
    }
}
