import SwiftUI
import WidgetKit
import OmegaJournalShared
import OmegaJournalWidgetUI

// MARK: - Bundle

/// Entry point. The packaging scripts link this target with
/// `-e _NSExtensionMain` (as Xcode does for app extensions) and wrap it into
/// Contents/PlugIns/OmegaJournalWidgets.appex.
@main
struct OmegaJournalWidgetBundle: WidgetBundle {
    var body: some Widget {
        OmegaTodayWidget()
    }
}

// MARK: - Configuration from Info.plist

/// Values packaging wrote into the extension's Info.plist.
enum WidgetConfig {
    static var appGroup: String? {
        OmegaJournalAppGroup.identifier(infoDictionary: Bundle.main.infoDictionary)
    }

    static var scheme: String {
        (Bundle.main.object(forInfoDictionaryKey: OmegaJournalLink.schemeInfoKey) as? String)
            .flatMap { $0.isEmpty || $0.hasPrefix("@") ? nil : $0 } ?? OmegaJournalLink.productionScheme
    }

    static func url(_ link: OmegaJournalLink) -> URL { link.url(scheme: scheme) }
}

// MARK: - Timeline

struct OmegaWidgetEntry: TimelineEntry {
    let date: Date
    let state: WidgetDisplayState
}

struct OmegaTodayProvider: TimelineProvider {
    func placeholder(in context: Context) -> OmegaWidgetEntry {
        OmegaWidgetEntry(date: Date(), state: .sample(at: Date()))
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (OmegaWidgetEntry) -> Void) {
        let now = Date()
        let snapshot = loadSnapshot()
        // The gallery preview shows sample numbers until the app has synced once.
        let state = context.isPreview && snapshot == nil ? .sample(at: now) : WidgetDisplay.state(for: snapshot, at: now)
        completion(OmegaWidgetEntry(date: now, state: state))
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<OmegaWidgetEntry>) -> Void) {
        let now = Date()
        let snapshot = loadSnapshot()
        let entries = WidgetDisplay.timelineDates(for: snapshot, now: now).map {
            OmegaWidgetEntry(date: $0, state: WidgetDisplay.state(for: snapshot, at: $0))
        }
        // The app reloads timelines whenever its numbers change; past the last
        // precomputed day there is nothing new to show until it does.
        completion(Timeline(entries: entries, policy: .atEnd))
    }

    private func loadSnapshot() -> WidgetSnapshot? {
        guard let group = WidgetConfig.appGroup else { return nil }
        return WidgetSnapshotStore.appGroup(group)?.read()
    }
}

// MARK: - Widget

struct OmegaTodayWidget: Widget {
    static let kind = "OmegaJournalToday"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: OmegaTodayProvider()) { entry in
            OmegaTodayWidgetView(entry: entry)
        }
        .configurationDisplayName("Today in Omega Journal")
        .description("Today's words, your streak and the daily prompt. Never shows what you wrote.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct OmegaTodayWidgetView: View {
    let entry: OmegaWidgetEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            switch family {
            case .systemMedium:
                OmegaMediumWidgetView(state: entry.state, newEntryURL: WidgetConfig.url(.newEntry))
            default:
                OmegaSmallWidgetView(state: entry.state)
            }
        }
        .widgetURL(WidgetConfig.url(.today))
        .containerBackground(for: .widget) { OmegaWidgetBackground() }
    }
}
