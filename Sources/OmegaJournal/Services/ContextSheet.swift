import AppKit
import OmegaJournalCore
import SwiftUI

// MARK: - "Add context" sheet
//
// Opened from the editor's "Add context" button. Fetches the enabled sources
// once, then lets the user choose what to keep: the place, today's events, and
// any of the day's photos. Nothing is written until "Add to entry".
// The editor applies the result (it owns the body text and attachment refs):
//
//     ContextSheet(service: contextService) { transform, photos in
//         body_ = transform(body_)
//         for p in photos { insertImageReference(for: vm.addAttachment(to: entry, data: p.data,
//                                                                      filename: p.filename, mimeType: p.mimeType)) }
//     }

struct ContextSheet: View {
    let service: ContextService
    var day: Date = Date()
    /// `transform` adds the chosen place/events to a body; `photos` are the picked files.
    let onApply: (_ transform: @escaping (String) -> String, _ photos: [ContextPhotoFile]) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let theme = ThemeManager.shared

    @State private var snapshot: ContextSnapshot?
    @State private var keepPlace = true
    @State private var keepEvents = true
    @State private var pickedPhotos: Set<String> = []
    @State private var isApplying = false

    var body: some View {
        VStack(alignment: .leading, spacing: OmegaTheme.Spacing.l) {
            header
            if service.enabled.isEmpty {
                ContextEmptyState(message: "Turn on a source below to add your place, today's events or today's photos to this entry.")
                ContextSourcesSection(service: service)
            } else if let snap = snapshot {
                ScrollView { results(snap) }
                    .frame(maxHeight: 420)
            } else {
                HStack(spacing: OmegaTheme.Spacing.s) {
                    ProgressView().controlSize(.small)
                    Text("Looking up today's context…")
                        .font(OmegaTheme.bodyFont)
                        .foregroundStyle(theme.secondaryTextColor)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
                .accessibilityElement(children: .combine)
            }
            footer
        }
        .padding(OmegaTheme.Spacing.xl)
        .frame(width: 480)
        .background(theme.surface0)
        .task(id: service.enabled.rawValue) { await load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: OmegaTheme.Spacing.xs) {
            Text("Add context")
                .font(OmegaTheme.headingFont)
                .foregroundStyle(theme.titleTextColor)
                .accessibilityAddTraits(.isHeader)
            Text("Choose what to add. Only what you pick is saved, encrypted with this entry.")
                .font(OmegaTheme.metaFont)
                .foregroundStyle(theme.secondaryTextColor)
        }
    }

    @ViewBuilder
    private func results(_ snap: ContextSnapshot) -> some View {
        VStack(alignment: .leading, spacing: OmegaTheme.Spacing.m) {
            if snap.isEmpty && snap.problems.isEmpty {
                ContextEmptyState(message: "Nothing to add for today yet.")
            }
            if let place = snap.place {
                Toggle(isOn: $keepPlace) {
                    Label(place.name, systemImage: "mappin.and.ellipse")
                        .font(OmegaTheme.bodyFont)
                        .foregroundStyle(theme.bodyTextColor)
                }
                .toggleStyle(.checkbox)
                .accessibilityLabel("Add place: \(place.name)")
            }
            if !snap.events.isEmpty {
                Toggle(isOn: $keepEvents) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(snap.events.count == 1 ? "1 event today" : "\(snap.events.count) events today", systemImage: "calendar")
                            .font(OmegaTheme.bodyFont)
                            .foregroundStyle(theme.bodyTextColor)
                        Text(snap.events.prefix(3).map(\.title).joined(separator: " · "))
                            .font(OmegaTheme.metaFont)
                            .foregroundStyle(theme.secondaryTextColor)
                            .lineLimit(1)
                    }
                }
                .toggleStyle(.checkbox)
                .accessibilityLabel("Add today's \(snap.events.count == 1 ? "event" : "events") to the entry")
            }
            if !snap.photos.isEmpty {
                VStack(alignment: .leading, spacing: OmegaTheme.Spacing.s) {
                    Text("Today's photos")
                        .font(OmegaTheme.captionFont)
                        .foregroundStyle(theme.secondaryTextColor)
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(96), spacing: OmegaTheme.Spacing.s), count: 4),
                              alignment: .leading, spacing: OmegaTheme.Spacing.s) {
                        ForEach(snap.photos) { photo in photoTile(photo) }
                    }
                }
            }
            ForEach(snap.problems, id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.circle")
                    .font(OmegaTheme.metaFont)
                    .foregroundStyle(theme.warningColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func photoTile(_ photo: ContextPhoto) -> some View {
        let picked = pickedPhotos.contains(photo.id)
        let time = photo.created?.formatted(date: .omitted, time: .shortened) ?? "photo"
        return Button {
            if picked { pickedPhotos.remove(photo.id) } else { pickedPhotos.insert(photo.id) }
        } label: {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let image = photo.thumbnail {
                        Image(nsImage: image).resizable().scaledToFill()
                    } else {
                        theme.surface2.overlay(Image(systemName: "photo").foregroundStyle(theme.secondaryTextColor))
                    }
                }
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: OmegaTheme.Radius.control))
                .overlay(RoundedRectangle(cornerRadius: OmegaTheme.Radius.control)
                    .strokeBorder(picked ? theme.accentColor : theme.borderColor, lineWidth: picked ? 3 : 1))
                if picked {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(ThemeManager.onAccent(for: theme.accentColor), theme.accentColor)
                        .font(.system(size: 18))
                        .padding(OmegaTheme.Spacing.xs)
                        .transition(reduceMotion ? .identity : .scale.combined(with: .opacity))
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: picked)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Photo taken at \(time)")
        .accessibilityValue(picked ? "Selected" : "Not selected")
        .accessibilityAddTraits(picked ? .isSelected : [])
    }

    private var footer: some View {
        HStack {
            if service.enabled.isEmpty == false {
                Text(summary)
                    .font(OmegaTheme.metaFont)
                    .foregroundStyle(theme.secondaryTextColor)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Add to entry") { Task { await apply() } }
                .keyboardShortcut(.defaultAction)
                .disabled(!canApply || isApplying)
        }
    }

    private var canApply: Bool {
        guard let s = snapshot else { return false }
        return (keepPlace && s.place != nil) || (keepEvents && !s.events.isEmpty) || !pickedPhotos.isEmpty
    }

    private var summary: String {
        pickedPhotos.isEmpty ? "" : pickedPhotos.count == 1 ? "1 photo selected" : "\(pickedPhotos.count) photos selected"
    }

    private func load() async {
        snapshot = nil
        guard !service.enabled.isEmpty else { return }
        snapshot = await service.gather(.explicit, day: day)
    }

    private func apply() async {
        guard let snap = snapshot else { return }
        isApplying = true
        defer { isApplying = false }
        let chosen = snap.photos.filter { pickedPhotos.contains($0.id) }
        let files = await service.files(for: chosen)
        let place = keepPlace, events = keepEvents
        onApply({ ContextService.apply(snap, to: $0, includePlace: place, includeEvents: events) }, files)
        dismiss()
    }
}

private struct ContextEmptyState: View {
    let message: String
    private let theme = ThemeManager.shared
    var body: some View {
        Text(message)
            .font(OmegaTheme.bodyFont)
            .foregroundStyle(theme.secondaryTextColor)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Settings section

/// Per-source switches (all off by default). Turning one on asks macOS for
/// that permission the first time; if access is refused the switch stays off
/// and explains where to change it.
struct ContextSourcesSection: View {
    let service: ContextService
    private let theme = ThemeManager.shared
    @State private var message: String?

    var body: some View {
        let enabled = service.enabled
        VStack(alignment: .leading, spacing: OmegaTheme.Spacing.s) {
            row(.place, title: "Place", detail: "Your current place name, looked up with Apple Maps.", icon: "mappin.and.ellipse", on: enabled.contains(.place))
            row(.calendar, title: "Calendar", detail: "Titles and times of today's events. Read only.", icon: "calendar", on: enabled.contains(.calendar))
            row(.photos, title: "Photos", detail: "Today's photos to choose from. Only the ones you pick are copied.", icon: "photo.on.rectangle", on: enabled.contains(.photos))
            Toggle("Add place and events to new entries automatically", isOn: Binding(
                get: { service.autoOnNewEntry },
                set: { service.autoOnNewEntry = $0 }))
                .font(OmegaTheme.bodyFont)
                .disabled(enabled.intersection([.place, .calendar]).isEmpty)
                .padding(.top, OmegaTheme.Spacing.xs)
            if let message {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(OmegaTheme.metaFont)
                    .foregroundStyle(theme.warningColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Weather isn't offered: it would need an online weather service.")
                .font(OmegaTheme.metaFont)
                .foregroundStyle(theme.secondaryTextColor)
        }
    }

    private func row(_ source: ContextSources, title: String, detail: String, icon: String, on: Bool) -> some View {
        Toggle(isOn: Binding(get: { on }, set: { newValue in
            Task { @MainActor in
                message = nil
                if newValue {
                    if await service.enable(source) == false {
                        message = ContextError.notAllowed(source).localizedDescription
                    }
                } else {
                    service.disable(source)
                }
            }
        })) {
            HStack(alignment: .firstTextBaseline, spacing: OmegaTheme.Spacing.s) {
                Image(systemName: icon)
                    .foregroundStyle(theme.accentColor)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(OmegaTheme.bodyFont).foregroundStyle(theme.bodyTextColor)
                    Text(detail).font(OmegaTheme.metaFont).foregroundStyle(theme.secondaryTextColor)
                }
            }
        }
        .toggleStyle(.switch)
        .accessibilityLabel("Add \(title.lowercased()) context")
        .accessibilityHint(detail)
    }
}
