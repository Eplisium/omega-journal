import AppKit
import CoreLocation
import EventKit
import Foundation
import MapKit
import Observation
import OmegaJournalCore
import Photos

// MARK: - Automatic context: place, calendar, photos
//
// Opt-in per source (all OFF by default) and only ever on explicit user action
// ("Add context" in the editor) — or on a new entry when the user turned that
// on too. Each source asks for its own macOS permission the first time it is
// used. Nothing leaves the Mac except the coordinate Apple Maps needs to name
// the place. Weather is not offered: WeatherKit needs a provisioned App ID
// capability this app doesn't have, and no third-party service is used.
//
// Every system framework sits behind a small protocol so the service is tested
// with fakes; the live providers are only created by `ContextService.live`.

/// Per-source settings (UserDefaults; default OFF).
struct ContextSettings {
    static let placeKey = "context.place.enabled"
    static let calendarKey = "context.calendar.enabled"
    static let photosKey = "context.photos.enabled"
    static let autoKey = "context.autoOnNewEntry"

    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var enabled: ContextSources {
        var s: ContextSources = []
        if defaults.bool(forKey: Self.placeKey) { s.insert(.place) }
        if defaults.bool(forKey: Self.calendarKey) { s.insert(.calendar) }
        if defaults.bool(forKey: Self.photosKey) { s.insert(.photos) }
        return s
    }

    var autoOnNewEntry: Bool { defaults.bool(forKey: Self.autoKey) }

    func set(_ source: ContextSources, _ on: Bool) {
        if source.contains(.place) { defaults.set(on, forKey: Self.placeKey) }
        if source.contains(.calendar) { defaults.set(on, forKey: Self.calendarKey) }
        if source.contains(.photos) { defaults.set(on, forKey: Self.photosKey) }
    }

    func setAutoOnNewEntry(_ on: Bool) { defaults.set(on, forKey: Self.autoKey) }
}

enum ContextAccess: Equatable, Sendable {
    case notDetermined, granted, denied
}

/// A named place, optionally with the coordinate used for the map.
struct ContextPlace: Equatable, Sendable {
    let name: String
    let coordinate: PlaceCoordinate?
}

/// A library photo offered for attaching.
struct ContextPhoto: Identifiable, Equatable {
    let id: String
    let created: Date?
    var thumbnail: NSImage?

    static func == (a: ContextPhoto, b: ContextPhoto) -> Bool { a.id == b.id && a.created == b.created }
}

/// The full-size bytes of a photo the user chose to attach.
struct ContextPhotoFile: Equatable, Sendable {
    let data: Data
    let filename: String
    let mimeType: String
}

// MARK: Provider seams

protocol ContextPlaceProviding {
    func access() -> ContextAccess
    func requestAccess() async -> Bool
    func currentPlace() async throws -> ContextPlace
}

protocol ContextCalendarProviding {
    func access() -> ContextAccess
    func requestAccess() async -> Bool
    func events(from start: Date, to end: Date) async throws -> [ContextEvent]
}

protocol ContextPhotosProviding {
    func access() -> ContextAccess
    func requestAccess() async -> Bool
    func photos(from start: Date, to end: Date, limit: Int) async -> [ContextPhoto]
    func file(for id: String) async -> ContextPhotoFile?
}

enum ContextError: Error, Equatable, LocalizedError {
    case notAllowed(ContextSources)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .notAllowed(let s):
            let what = s == .place ? "Location" : s == .calendar ? "Calendars" : "Photos"
            return "Omega Journal doesn't have access to \(what). You can allow it in System Settings › Privacy & Security › \(what)."
        case .unavailable(let message): return message
        }
    }
}

// MARK: - Service

/// What one "Add context" run found. Each part is independent: a refused
/// permission or a failed lookup only empties that part.
struct ContextSnapshot: Equatable {
    var place: ContextPlace?
    var events: [ContextEvent] = []
    var photos: [ContextPhoto] = []
    /// Plain-English problems to show next to the source that failed.
    var problems: [String] = []

    var eventsMarkdown: String? { ContextFormatting.eventsMarkdown(events) }
    var isEmpty: Bool { place == nil && events.isEmpty && photos.isEmpty }
}

@MainActor
@Observable
final class ContextService {
    @ObservationIgnored let settings: ContextSettings
    @ObservationIgnored private let place: ContextPlaceProviding
    @ObservationIgnored private let calendar: ContextCalendarProviding
    @ObservationIgnored private let photos: ContextPhotosProviding
    private(set) var isWorking = false
    /// Bumped whenever a setting changes so views re-read `enabled`.
    private(set) var revision = 0

    /// Enabled sources (observable).
    var enabled: ContextSources { _ = revision; return settings.enabled }
    var autoOnNewEntry: Bool {
        get { _ = revision; return settings.autoOnNewEntry }
        set { settings.setAutoOnNewEntry(newValue); revision += 1 }
    }

    init(settings: ContextSettings = ContextSettings(), place: ContextPlaceProviding,
         calendar: ContextCalendarProviding, photos: ContextPhotosProviding) {
        self.settings = settings
        self.place = place
        self.calendar = calendar
        self.photos = photos
    }

    /// App-wide instance for the editor and Settings. Created on first use;
    /// creating it asks for nothing.
    static let shared = ContextService.live()

    /// Real system providers. Creating them asks for nothing.
    static func live(settings: ContextSettings = ContextSettings()) -> ContextService {
        ContextService(settings: settings, place: LiveContextPlace(), calendar: LiveContextCalendar(), photos: LiveContextPhotos())
    }

    func access(for source: ContextSources) -> ContextAccess {
        switch source {
        case .place: place.access()
        case .calendar: calendar.access()
        case .photos: photos.access()
        default: .notDetermined
        }
    }

    /// Turns a source on: asks macOS for permission first (only when undecided)
    /// and leaves the setting off if access is refused. Returns the result.
    @discardableResult
    func enable(_ source: ContextSources) async -> Bool {
        let granted: Bool
        switch access(for: source) {
        case .granted: granted = true
        case .denied: granted = false
        case .notDetermined:
            switch source {
            case .place: granted = await place.requestAccess()
            case .calendar: granted = await calendar.requestAccess()
            case .photos: granted = await photos.requestAccess()
            default: granted = false
            }
        }
        settings.set(source, granted)
        revision += 1
        return granted
    }

    func disable(_ source: ContextSources) {
        settings.set(source, false)
        revision += 1
    }

    /// Fetches the enabled sources for `trigger` on `day`. Never prompts for
    /// a permission that was not asked for when the source was enabled.
    func gather(_ trigger: ContextTrigger, day: Date = Date(), cal: Calendar = .current, photoLimit: Int = 24) async -> ContextSnapshot {
        let wanted = ContextPolicy.sources(for: trigger, enabled: settings.enabled, autoOnNewEntry: settings.autoOnNewEntry)
        var snap = ContextSnapshot()
        guard !wanted.isEmpty else { return snap }
        isWorking = true
        defer { isWorking = false }
        let (start, end) = ContextFormatting.dayInterval(day, calendar: cal)
        if wanted.contains(.place) {
            if place.access() == .granted {
                do { snap.place = try await place.currentPlace() } catch {
                    snap.problems.append("Couldn't find your location right now.")
                }
            } else {
                snap.problems.append(ContextError.notAllowed(.place).localizedDescription)
            }
        }
        if wanted.contains(.calendar) {
            if calendar.access() == .granted {
                do { snap.events = try await calendar.events(from: start, to: end) } catch {
                    snap.problems.append("Couldn't read today's calendar.")
                }
            } else {
                snap.problems.append(ContextError.notAllowed(.calendar).localizedDescription)
            }
        }
        if wanted.contains(.photos) {
            if photos.access() == .granted {
                snap.photos = await photos.photos(from: start, to: end, limit: photoLimit)
            } else {
                snap.problems.append(ContextError.notAllowed(.photos).localizedDescription)
            }
        }
        return snap
    }

    /// Full-size bytes for photos the user picked (copied into the entry's
    /// encrypted attachments by the caller).
    func files(for picked: [ContextPhoto]) async -> [ContextPhotoFile] {
        var out: [ContextPhotoFile] = []
        for p in picked { if let f = await photos.file(for: p.id) { out.append(f) } }
        return out
    }

    /// Applies place and events to a body (no photos): the place goes into
    /// the place stamp, events become a short list before it.
    static func apply(_ snap: ContextSnapshot, to body: String, includePlace: Bool = true, includeEvents: Bool = true) -> String {
        var out = body
        if includeEvents, let md = snap.eventsMarkdown { out = ContextFormatting.insertingEvents(md, into: out) }
        if includePlace, let p = snap.place { out = PlaceStampCodec.settingPlace(p.name, coordinate: p.coordinate, on: out) }
        return out
    }
}

// MARK: - Live providers

/// CoreLocation for the fix, MapKit (macOS 26) or CLGeocoder (older) for the name.
final class LiveContextPlace: NSObject, ContextPlaceProviding, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var authWaiters: [CheckedContinuation<Bool, Never>] = []
    private var fixWaiters: [CheckedContinuation<CLLocation, Error>] = []

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func access() -> ContextAccess {
        switch manager.authorizationStatus {
        case .notDetermined: .notDetermined
        case .authorizedAlways, .authorized: .granted
        default: .denied
        }
    }

    func requestAccess() async -> Bool {
        guard access() == .notDetermined else { return access() == .granted }
        return await withCheckedContinuation { c in
            authWaiters.append(c)
            manager.requestWhenInUseAuthorization()
        }
    }

    func currentPlace() async throws -> ContextPlace {
        let fix: CLLocation = try await withCheckedThrowingContinuation { c in
            fixWaiters.append(c)
            manager.requestLocation()
        }
        let coordinate = PlaceCoordinate(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude)
        let name = await Self.name(for: fix) ?? Self.coordinateLabel(coordinate)
        return ContextPlace(name: name, coordinate: coordinate.isValid ? coordinate : nil)
    }

    static func coordinateLabel(_ c: PlaceCoordinate) -> String {
        String(format: "%.3f, %.3f", locale: Locale(identifier: "en_US_POSIX"), c.latitude, c.longitude)
    }

    static func name(for location: CLLocation) async -> String? {
        if #available(macOS 26.0, *) {
            guard let request = MKReverseGeocodingRequest(location: location),
                  let item = try? await request.mapItems.first else { return nil }
            let reps = item.addressRepresentations
            return ContextFormatting.placeLabel(name: item.name, locality: reps?.cityName, area: reps?.regionName, country: nil)
        } else {
            guard let mark = try? await CLGeocoder().reverseGeocodeLocation(location).first else { return nil }
            return ContextFormatting.placeLabel(name: mark.name, locality: mark.locality,
                                                area: mark.administrativeArea, country: mark.country)
        }
    }

    // Delegate callbacks arrive on the main thread (the manager was made there).
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            guard access() != .notDetermined else { return }
            let granted = access() == .granted
            let waiters = authWaiters
            authWaiters.removeAll()
            waiters.forEach { $0.resume(returning: granted) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated {
            guard let last = locations.last else { return }
            let waiters = fixWaiters
            fixWaiters.removeAll()
            waiters.forEach { $0.resume(returning: last) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            let waiters = fixWaiters
            fixWaiters.removeAll()
            waiters.forEach { $0.resume(throwing: ContextError.unavailable(error.localizedDescription)) }
        }
    }
}

/// EventKit, read-only: titles and times of the day's events.
final class LiveContextCalendar: ContextCalendarProviding {
    private let store = EKEventStore()

    func access() -> ContextAccess {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    func events(from start: Date, to end: Date) async throws -> [ContextEvent] {
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).map {
            ContextEvent(title: $0.title ?? "", start: $0.startDate, end: $0.endDate, isAllDay: $0.isAllDay)
        }
    }
}

/// PhotoKit: the day's photos as thumbnails; full bytes only for picked ones.
final class LiveContextPhotos: ContextPhotosProviding {
    func access() -> ContextAccess {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized, .limited: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    func requestAccess() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return status == .authorized || status == .limited
    }

    func photos(from start: Date, to end: Date, limit: Int) async -> [ContextPhoto] {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "creationDate >= %@ AND creationDate < %@", start as NSDate, end as NSDate)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        options.fetchLimit = limit
        let result = PHAsset.fetchAssets(with: .image, options: options)
        var assets: [PHAsset] = []
        result.enumerateObjects { a, _, _ in assets.append(a) }
        var out: [ContextPhoto] = []
        for a in assets {
            let thumb = await Self.thumbnail(a)
            out.append(ContextPhoto(id: a.localIdentifier, created: a.creationDate, thumbnail: thumb))
        }
        return out
    }

    func file(for id: String) async -> ContextPhotoFile? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject,
              let (data, uti) = await Self.fullData(asset) else { return nil }
        let type = UTType(uti ?? "") ?? .jpeg
        let ext = type.preferredFilenameExtension ?? "jpg"
        return ContextPhotoFile(data: data, filename: ContextFormatting.photoFilename(created: asset.creationDate, uniformTypeExtension: ext),
                                mimeType: type.preferredMIMEType ?? "image/jpeg")
    }

    // Completion handlers run on PhotoKit's queues: keep these closures nonisolated.
    nonisolated private static func thumbnail(_ asset: PHAsset) async -> NSImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.resizeMode = .fast
        let image: NSImage? = await withCheckedContinuation { (c: CheckedContinuation<NSImage?, Never>) in
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 240, height: 240),
                                                  contentMode: .aspectFill, options: options) { image, _ in
                c.resume(returning: image)
            }
        }
        return image
    }

    nonisolated private static func fullData(_ asset: PHAsset) async -> (Data, String?)? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.version = .current
        let pair: (Data, String?)? = await withCheckedContinuation { (c: CheckedContinuation<(Data, String?)?, Never>) in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, uti, _, _ in
                c.resume(returning: data.map { ($0, uti) })
            }
        }
        return pair
    }
}
