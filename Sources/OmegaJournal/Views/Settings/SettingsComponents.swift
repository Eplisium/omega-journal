import SwiftUI
import OmegaJournalCore

// MARK: - Settings card

/// The one container for settings content: a small section header (icon chip +
/// name) above a rounded card body, with an optional footnote underneath.
/// Build every settings pane from these so new areas stay consistent.
struct SettingsCard<Content: View>: View {
    let title: String
    let icon: String
    var footnote: String?
    let content: Content

    @ObservedObject private var theme = ThemeManager.shared

    init(
        title: String,
        icon: String,
        footnote: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.icon = icon
        self.footnote = footnote
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(OmegaTheme.font(.meta, .semibold))
                    .foregroundColor(theme.accentColor)
                    .frame(width: 22, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(theme.accentColor.opacity(0.14))
                    )
                Text(title)
                    .font(OmegaTheme.font(.meta, .semibold))
                    .tracking(0.5)
                    .foregroundColor(theme.secondaryTextColor)
            }

            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(theme.cardColor.opacity(0.45))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        theme.colorScheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.08),
                        lineWidth: 1
                    )
            )

            if let footnote {
                Text(footnote)
                    .font(OmegaTheme.font(.meta))
                    .foregroundColor(theme.secondaryTextColor)
                    .padding(.leading, 2)
            }
        }
    }
}

// MARK: - Settings rows

/// Standard settings row: label (+ optional subtitle/icon) on the left, any
/// trailing control on the right. Pair with `SettingsRowDivider` between rows.
struct SettingsRow<Trailing: View>: View {
    let title: String
    var subtitle: String?
    var icon: String?
    let trailing: Trailing

    @ObservedObject private var theme = ThemeManager.shared

    init(
        title: String,
        subtitle: String? = nil,
        icon: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 10) {
            if let icon {
                Image(systemName: icon)
                    .font(OmegaTheme.font(.caption))
                    .foregroundColor(theme.accentColor)
                    .frame(width: 18)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(OmegaTheme.font(.caption, .medium))
                    .foregroundColor(theme.titleTextColor)
                if let subtitle {
                    Text(subtitle)
                        .font(OmegaTheme.font(.meta))
                        .foregroundColor(theme.secondaryTextColor)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.vertical, 5)
    }
}

/// Read-only label/value row for stats and metadata.
struct SettingsValueRow: View {
    let title: String
    let value: String

    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(OmegaTheme.font(.meta))
                .foregroundColor(theme.secondaryTextColor)
            Spacer(minLength: 12)
            Text(value)
                .font(OmegaTheme.font(.meta, design: .rounded))
                .foregroundColor(theme.bodyTextColor)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 4)
    }
}

/// Hairline between rows inside a `SettingsCard`.
struct SettingsRowDivider: View {
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        Rectangle()
            .fill(theme.secondaryTextColor.opacity(0.12))
            .frame(height: 1)
    }
}

// MARK: - Settings pill button

/// Capsule action button used across settings. `prominent` fills with the
/// accent color for primary actions; `destructive` tints red.
struct SettingsPillButton: View {
    let title: String
    let icon: String
    var prominent: Bool = false
    var destructive: Bool = false
    let action: () -> Void

    @ObservedObject private var theme = ThemeManager.shared
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(OmegaTheme.font(.meta, .semibold))
                Text(title)
                    .font(OmegaTheme.font(.meta, .semibold))
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundColor(foreground)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(background))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(nil, value: isHovered)
    }

    private var foreground: Color {
        if destructive { return Color.red.opacity(isHovered ? 1.0 : 0.9) }
        if prominent { return .white }
        return theme.accentColor
    }

    private var background: Color {
        if destructive { return Color.red.opacity(isHovered ? 0.22 : 0.13) }
        if prominent { return theme.accentColor.opacity(isHovered ? 1.0 : 0.85) }
        return theme.accentColor.opacity(isHovered ? 0.22 : 0.14)
    }
}

// MARK: - Goal target field

/// Click-to-edit numeric field for goal targets. Commits on Return or when
/// focus leaves; values clamp to 1...10000. Replaces the old Stepper, whose
/// arrows silently failed and looked out of place.
struct GoalTargetField: View {
    let target: Int
    let unit: String
    var label: String = "Target"
    let onCommit: (Int) -> Void

    @ObservedObject private var theme = ThemeManager.shared
    @State private var text: String
    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    init(
        target: Int,
        unit: String,
        label: String = "Target",
        onCommit: @escaping (Int) -> Void
    ) {
        self.target = target
        self.unit = unit
        self.label = label
        self.onCommit = onCommit
        self._text = State(initialValue: String(target))
    }

    var body: some View {
        HStack(spacing: 5) {
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(OmegaTheme.font(.caption, .semibold, design: .rounded))
                .foregroundColor(theme.titleTextColor)
                .multilineTextAlignment(.trailing)
                .frame(width: 48)
                .focused($isFocused)
                .onSubmit(commit)
            Text(unit)
                .font(OmegaTheme.font(.meta))
                .foregroundColor(theme.secondaryTextColor)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.secondaryTextColor.opacity(isFocused ? 0.12 : 0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    isFocused
                        ? theme.accentColor.opacity(0.7)
                        : theme.secondaryTextColor.opacity(isHovered ? 0.28 : 0.16),
                    lineWidth: 1
                )
        )
        .onHover { isHovered = $0 }
        .onChange(of: isFocused) { _, focused in
            if !focused { commit() }
        }
        .onChange(of: target) { _, newValue in
            // Keep the field in sync when the target changes elsewhere,
            // without stomping on in-progress typing.
            if !isFocused, text != "\(newValue)" { text = "\(newValue)" }
        }
        .accessibilityLabel(label)
    }

    private func commit() {
        // Digits-only parse so values pasted with separators ("1,500") work.
        let parsed = Int(text.filter(\.isNumber)) ?? target
        let clamped = max(1, min(parsed, 10000))
        text = "\(clamped)"
        if clamped != target {
            onCommit(clamped)
        }
    }
}

// MARK: - Sidebar row

/// Navigation row for the settings sidebar: icon + label with selected and
/// hover states.
struct SettingsSidebarRow: View {
    let section: SettingsSection
    let isSelected: Bool
    let action: () -> Void

    @ObservedObject private var theme = ThemeManager.shared
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: section.icon)
                    .font(OmegaTheme.font(.meta, .medium))
                    .foregroundColor(isSelected ? theme.accentColor : theme.secondaryTextColor)
                    .frame(width: 18)
                Text(section.rawValue)
                    .font(OmegaTheme.font(.meta, isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? theme.titleTextColor : theme.bodyTextColor)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        isSelected
                            ? theme.accentColor.opacity(0.16)
                            : (isHovered ? theme.secondaryTextColor.opacity(0.08) : .clear)
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
