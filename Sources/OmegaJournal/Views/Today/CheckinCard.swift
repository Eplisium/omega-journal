import SwiftUI
import OmegaJournalCore

// MARK: - Daily check-in card

/// Structured daily check-in: sleep, energy, stress and any custom metrics.
/// Embed standalone: `CheckinCard()`.
struct CheckinCard: View {
    @ObservedObject var store: CheckinStore = .shared
    @ObservedObject private var theme = ThemeManager.shared
    @State private var showAdd = false
    @State private var isEditing = false
    @State private var newName = ""
    @State private var newKind: CheckinMetricKind = .scale
    @State private var newUnit = ""

    var body: some View {
        OmegaCard {
            VStack(alignment: .leading, spacing: OmegaTheme.Spacing.m) {
                OmegaSectionHeader(title: "Daily check-in", subtitle: "How are you today?", systemImage: "heart.text.square") {
                    HStack(spacing: OmegaTheme.Spacing.s) {
                        OmegaIconButton(systemImage: isEditing ? "checkmark" : "slider.horizontal.3",
                                        accessibilityLabel: isEditing ? "Done editing metrics" : "Edit metrics") { isEditing.toggle() }
                        OmegaIconButton(systemImage: "plus", accessibilityLabel: "Add a metric") { showAdd = true }
                    }
                }
                ForEach(store.metrics) { metric in
                    HStack(spacing: OmegaTheme.Spacing.m) {
                        Image(systemName: metric.icon)
                            .font(OmegaTheme.font(.caption, .semibold))
                            .foregroundColor(theme.accentColor)
                            .frame(width: 18)
                            .accessibilityHidden(true)
                        Text(metric.name)
                            .font(OmegaTheme.bodyFont)
                            .foregroundColor(theme.titleTextColor)
                            .frame(width: 84, alignment: .leading)
                        MetricInput(metric: metric, store: store)
                        Spacer(minLength: 0)
                        if isEditing {
                            Button { store.removeMetric(metric.id) } label: {
                                Image(systemName: "minus.circle.fill").foregroundColor(theme.dangerColor)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(metric.name)")
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showAdd) { addSheet }
    }

    private var addSheet: some View {
        VStack(alignment: .leading, spacing: OmegaTheme.Spacing.l) {
            Text("New metric").font(OmegaTheme.headingFont).foregroundColor(theme.titleTextColor)
            TextField("Name (e.g. Water, Focus)", text: $newName).textFieldStyle(.roundedBorder)
            Picker("Type", selection: $newKind) {
                Text("1–5 scale").tag(CheckinMetricKind.scale)
                Text("Number").tag(CheckinMetricKind.number)
            }
            .pickerStyle(.segmented)
            if newKind == .number {
                TextField("Unit (optional)", text: $newUnit).textFieldStyle(.roundedBorder)
            }
            HStack {
                Spacer()
                Button("Cancel") { showAdd = false }
                Button("Add") {
                    if store.addMetric(name: newName, kind: newKind, unit: newUnit) {
                        newName = ""; newUnit = ""; showAdd = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(OmegaTheme.Spacing.xl)
        .frame(width: 340)
        .background(theme.backgroundColor)
    }
}

private struct MetricInput: View {
    let metric: CheckinMetric
    @ObservedObject var store: CheckinStore
    @ObservedObject private var theme = ThemeManager.shared
    @State private var text = ""

    var body: some View {
        switch metric.kind {
        case .scale:
            HStack(spacing: 6) {
                ForEach(1...5, id: \.self) { n in
                    let selected = store.value(metric.id) == Double(n)
                    Button {
                        store.setValue(metric.id, selected ? nil : Double(n))
                    } label: {
                        Text("\(n)")
                            .font(OmegaTheme.font(.caption, .semibold, design: .rounded))
                            .frame(width: 26, height: 26)
                            .foregroundColor(selected ? theme.onAccentColor : theme.secondaryTextColor)
                            .background(Circle().fill(selected ? theme.accentColor : theme.surface2))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(metric.name) \(n) of 5")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        case .number:
            HStack(spacing: 6) {
                TextField("–", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 64)
                    .onSubmit(commit)
                    .onAppear { text = format(store.value(metric.id)) }
                    .onChange(of: text) { _, _ in commit() }
                if !metric.unit.isEmpty {
                    Text(metric.unit).font(OmegaTheme.metaFont).foregroundColor(theme.secondaryTextColor)
                }
            }
        }
    }

    private func format(_ v: Double?) -> String {
        guard let v else { return "" }
        return v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        if trimmed.isEmpty { if store.value(metric.id) != nil { store.setValue(metric.id, nil) }; return }
        guard let v = Double(trimmed), v >= 0, v <= 10_000 else { return }
        if store.value(metric.id) != v { store.setValue(metric.id, v) }
    }
}

// MARK: - Habit strip

/// Row of tappable habit chips for today with streak counts. Embed standalone: `HabitStrip()`.
struct HabitStrip: View {
    @ObservedObject var store: CheckinStore = .shared
    @ObservedObject private var theme = ThemeManager.shared
    @State private var adding = false
    @State private var newName = ""

    var body: some View {
        OmegaCard {
            VStack(alignment: .leading, spacing: OmegaTheme.Spacing.m) {
                OmegaSectionHeader(title: "Habits", subtitle: store.habits.isEmpty ? "Track small daily things" : "Tap to check off today", systemImage: "checklist") {
                    OmegaIconButton(systemImage: "plus", accessibilityLabel: "Add a habit") { adding.toggle() }
                }
                if adding {
                    HStack {
                        TextField("New habit (e.g. Walk, Read)", text: $newName)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(add)
                        Button("Add", action: add).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                if store.habits.isEmpty && !adding {
                    Text("No habits yet. Add one to see it on your heatmap.")
                        .font(OmegaTheme.metaFont).foregroundColor(theme.secondaryTextColor)
                } else {
                    FlowLayout(spacing: OmegaTheme.Spacing.s) {
                        ForEach(store.habits) { habit in
                            let done = store.isDone(habit.id)
                            let streak = store.streak(habit.id)
                            Button { store.toggleHabit(habit.id) } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: done ? "checkmark.circle.fill" : "circle")
                                    Text(habit.name).lineLimit(1)
                                    if streak > 1 {
                                        Text("🔥\(streak)").font(OmegaTheme.metaFont)
                                    }
                                }
                                .font(OmegaTheme.font(.caption, .medium))
                                .foregroundColor(done ? theme.onAccentColor : theme.titleTextColor)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Capsule().fill(done ? theme.accentColor : theme.surface2))
                            }
                            .buttonStyle(.plain)
                            .contextMenu { Button("Delete habit", role: .destructive) { store.deleteHabit(habit.id) } }
                            .accessibilityLabel("\(habit.name), \(done ? "done" : "not done") today")
                            .accessibilityAddTraits(done ? .isSelected : [])
                        }
                    }
                }
            }
        }
    }

    private func add() {
        if store.addHabit(name: newName) { newName = ""; adding = false }
    }
}
