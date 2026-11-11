import MapKit
import OmegaJournalCore
import SwiftUI

// MARK: - Map of places
//
// Entries whose place stamp has coordinates (added with "Add context" or
// imported from Apple Journal), as clustered pins. Clicking a pin opens the
// entry; a cluster zooms in, or lists its entries when they share a spot.
// Privacy: built from `vm.calendarEntries` (already masked by the analytics
// visibility rule) and filtered again by `PlaceIndex` with the hidden lock,
// so a locked hidden entry never shows — not even as an anonymous pin.

struct EntryMapView: View {
    var vm: JournalViewModel

    private let theme = ThemeManager.shared
    private let biometricAuth = BiometricAuth.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var position: MapCameraPosition = .automatic
    @State private var span: (lat: Double, lon: Double) = (60, 60)
    @State private var presented: EntryDrillThroughRoute?
    @State private var listed: [PlacePoint] = []
    @State private var listAnchor: String?
    @State private var didFrame = false

    private var sources: [PlaceSourceEntry] {
        vm.calendarEntries.map {
            PlaceSourceEntry(id: $0.id, title: $0.title, body: $0.body, createdAt: $0.createdAt,
                             isHidden: $0.isHidden, isTrashed: $0.isTrashed)
        }
    }

    var body: some View {
        let hiddenLocked = !biometricAuth.isAuthenticated
        let src = sources
        let points = PlaceIndex.points(from: src, hiddenLocked: hiddenLocked)
        let namedOnly = PlaceIndex.namedOnlyCount(in: src, hiddenLocked: hiddenLocked)
        let clusters = PlaceIndex.clusters(points, latitudeSpan: span.lat, longitudeSpan: span.lon, cellsAcross: 8)

        ZStack(alignment: .top) {
            Map(position: $position) {
                ForEach(clusters) { cluster in
                    Annotation(cluster.isSingle ? cluster.points[0].title : "\(cluster.count) entries",
                               coordinate: CLLocationCoordinate2D(latitude: cluster.center.latitude, longitude: cluster.center.longitude),
                               anchor: .bottom) {
                        pin(cluster)
                    }
                    .annotationTitles(.hidden)
                }
            }
            .mapStyle(.standard(pointsOfInterest: .excludingAll))
            .mapControls {
                MapZoomStepper()
                MapCompass()
            }
            .onMapCameraChange(frequency: .onEnd) { context in
                span = (context.region.span.latitudeDelta, context.region.span.longitudeDelta)
            }
            .accessibilityLabel(points.isEmpty ? "Map with no entry places" : "Map of \(points.count) entries with places")

            if points.isEmpty {
                emptyState(namedOnly: namedOnly)
            } else {
                header(count: points.count, namedOnly: namedOnly)
            }
        }
        .background(theme.surface0)
        .onAppear { frame(points, animated: false) }
        .onChange(of: points.map(\.entryId)) { _, _ in
            if !didFrame { frame(points, animated: false) }
        }
        .onChange(of: hiddenLocked) { _, locked in
            // Re-lock: close anything showing a hidden entry.
            if locked { listed = []; listAnchor = nil }
        }
        .sheet(item: $presented, onDismiss: finishPresented) { route in
            EntryDrillThroughSheet(vm: vm, entryID: route.entryID, contextTitle: "Entry on the map")
        }
    }

    // MARK: Pins

    @ViewBuilder
    private func pin(_ cluster: PlaceCluster) -> some View {
        let single = cluster.isSingle
        let label = single
            ? "\(cluster.points[0].title), \(cluster.points[0].date.formatted(date: .abbreviated, time: .omitted))"
                + (cluster.points[0].placeName.isEmpty ? "" : ", \(cluster.points[0].placeName)")
            : "\(cluster.count) entries here"
        Button { tap(cluster) } label: {
            ZStack {
                Circle()
                    .fill(theme.accentColor)
                    .frame(width: single ? 26 : 34, height: single ? 26 : 34)
                    .overlay(Circle().strokeBorder(theme.surface0, lineWidth: 2))
                    .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                if single {
                    Image(systemName: "book.closed.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(ThemeManager.onAccent(for: theme.accentColor))
                } else {
                    Text("\(cluster.count)")
                        .font(OmegaTheme.font(.caption, .bold))
                        .foregroundStyle(ThemeManager.onAccent(for: theme.accentColor))
                }
            }
        }
        .buttonStyle(.plain)
        .help(single ? cluster.points[0].title : "\(cluster.count) entries")
        .accessibilityLabel(label)
        .accessibilityHint(single ? "Opens the entry" : "Shows these entries")
        .popover(isPresented: Binding(get: { listAnchor == cluster.id }, set: { if !$0 { listAnchor = nil } }),
                 arrowEdge: .bottom) {
            list(listed)
        }
    }

    private func tap(_ cluster: PlaceCluster) {
        switch PlaceIndex.action(for: cluster) {
        case .open(let id):
            open(id)
        case .zoom(let c, let latSpan, let lonSpan):
            let region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude),
                                            span: MKCoordinateSpan(latitudeDelta: latSpan, longitudeDelta: lonSpan))
            if reduceMotion { position = .region(region) } else { withAnimation(.easeInOut(duration: 0.35)) { position = .region(region) } }
        case .list(let points):
            listed = points
            listAnchor = cluster.id
        }
    }

    private func open(_ id: String) {
        listAnchor = nil
        guard let entry = vm.calendarEntries.first(where: { $0.id == id }) else { return }
        Task { @MainActor in
            guard await vm.revealIfNeeded(entry) else { return }
            presented = EntryDrillThroughRoute(entryID: id)
        }
    }

    private func finishPresented() {
        if let id = presented?.entryID, vm.editingEntryId == id { vm.stopEditing() }
        presented = nil
    }

    private func list(_ points: [PlacePoint]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(points.first?.placeName.isEmpty == false ? points[0].placeName : "\(points.count) entries")
                .font(OmegaTheme.captionFont)
                .foregroundStyle(theme.secondaryTextColor)
                .padding([.horizontal, .top], OmegaTheme.Spacing.m)
                .padding(.bottom, OmegaTheme.Spacing.xs)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(points) { p in
                        Button { open(p.entryId) } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(p.title).font(OmegaTheme.bodyFont).foregroundStyle(theme.titleTextColor).lineLimit(1)
                                Text(p.date.formatted(date: .abbreviated, time: .omitted))
                                    .font(OmegaTheme.metaFont).foregroundStyle(theme.secondaryTextColor)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, OmegaTheme.Spacing.m)
                            .padding(.vertical, OmegaTheme.Spacing.xs)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(p.title), \(p.date.formatted(date: .abbreviated, time: .omitted))")
                    }
                }
            }
            .frame(maxHeight: 260)
        }
        .padding(.bottom, OmegaTheme.Spacing.s)
        .frame(width: 260)
        .background(theme.surface1)
    }

    // MARK: Chrome

    private func header(count: Int, namedOnly: Int) -> some View {
        HStack(spacing: OmegaTheme.Spacing.s) {
            Label(count == 1 ? "1 entry with a place" : "\(count) entries with a place", systemImage: "map")
                .font(OmegaTheme.captionFont)
                .foregroundStyle(theme.titleTextColor)
            if namedOnly > 0 {
                Text("· \(namedOnly) more name a place without a map location")
                    .font(OmegaTheme.metaFont)
                    .foregroundStyle(theme.secondaryTextColor)
            }
            Spacer(minLength: 0)
            Button("Show all") { frame(PlaceIndex.points(from: sources, hiddenLocked: !biometricAuth.isAuthenticated), animated: true) }
                .controlSize(.small)
                .accessibilityHint("Zooms the map to fit every entry")
        }
        .padding(.horizontal, OmegaTheme.Spacing.m)
        .padding(.vertical, OmegaTheme.Spacing.s)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: OmegaTheme.Radius.card))
        .padding(OmegaTheme.Spacing.m)
        .accessibilityElement(children: .contain)
    }

    private func emptyState(namedOnly: Int) -> some View {
        VStack(spacing: OmegaTheme.Spacing.s) {
            Image(systemName: "map")
                .font(.system(size: 28))
                .foregroundStyle(theme.accentColor)
                .accessibilityHidden(true)
            Text("No places yet")
                .font(OmegaTheme.headingFont)
                .foregroundStyle(theme.titleTextColor)
            Text(namedOnly > 0
                 ? "\(namedOnly == 1 ? "1 entry names" : "\(namedOnly) entries name") a place but has no map location. Use Add context in the editor to pin where you are."
                 : "Use Add context in the editor to add where you are, or import from Apple Journal.")
                .font(OmegaTheme.bodyFont)
                .foregroundStyle(theme.secondaryTextColor)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .padding(OmegaTheme.Spacing.xl)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: OmegaTheme.Radius.sheet))
        .padding(.top, 80)
        .accessibilityElement(children: .combine)
    }

    private func frame(_ points: [PlacePoint], animated: Bool) {
        guard let r = PlaceIndex.boundingRegion(points) else { return }
        didFrame = true
        let region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: r.center.latitude, longitude: r.center.longitude),
                                        span: MKCoordinateSpan(latitudeDelta: r.latSpan, longitudeDelta: r.lonSpan))
        span = (r.latSpan, r.lonSpan)
        if animated && !reduceMotion {
            withAnimation(.easeInOut(duration: 0.35)) { position = .region(region) }
        } else {
            position = .region(region)
        }
    }
}
