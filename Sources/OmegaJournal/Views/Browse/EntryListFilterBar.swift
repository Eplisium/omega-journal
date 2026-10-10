import SwiftUI
import OmegaJournalCore

// MARK: - Filter Bar

struct FilterBar: View {
    @ObservedObject var vm: JournalViewModel
    @ObservedObject var theme = ThemeManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("FILTERS")
                    .font(OmegaTheme.font(.meta, .semibold))
                    .tracking(0.7)
                    .foregroundColor(theme.secondaryTextColor)
                Spacer()
                if vm.filter.isActive {
                    Button("Reset") { vm.filter = .empty }
                        .buttonStyle(.plain)
                        .font(OmegaTheme.font(.meta, .medium))
                        .foregroundColor(theme.accentColor)
                }
            }

            // Mood chips + date range
            HStack(spacing: 4) {
                ForEach(Mood.allCases) { mood in
                    let on = vm.filter.moods.contains(mood)
                    Button {
                        if on { vm.filter.moods.remove(mood) } else { vm.filter.moods.insert(mood) }
                    } label: {
                        Text(mood.emoji)
                            .font(OmegaTheme.font(.caption))
                            .frame(width: 24, height: 22)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(on ? mood.color.opacity(0.28) : theme.cardColor.opacity(0.5))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .strokeBorder(on ? mood.color.opacity(0.7) : .clear, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .omegaTooltip(mood.label)
                }

                Spacer()

                Picker("", selection: $vm.filter.dateRange) {
                    ForEach(EntryFilter.DateRange.allCases) { r in
                        Text(r.rawValue).tag(r)
                    }
                }
                .labelsHidden()
                .font(OmegaTheme.font(.meta))
                .fixedSize()
                .accessibilityLabel("Date range")
            }

            // Toggles get their own row so labels never wrap mid-word in a
            // narrow list column; the length stepper sits on the next row.
            HStack(spacing: 5) {
                toggle("Favorites", "star.fill", $vm.filter.favoritesOnly)
                toggle("Pinned", "pin.fill", $vm.filter.pinnedOnly)
                toggle("Files", "paperclip", $vm.filter.withAttachmentsOnly)
                Spacer(minLength: 0)
            }

            HStack(spacing: 5) {
                Text("Minimum words")
                    .font(OmegaTheme.font(.meta))
                    .foregroundColor(theme.secondaryTextColor)
                Stepper("", value: $vm.filter.minWords, in: 0...2000, step: 50)
                    .labelsHidden()
                Text("\(vm.filter.minWords)")
                    .font(OmegaTheme.font(.meta, design: .rounded))
                    .foregroundColor(theme.bodyTextColor)
                    .monospacedDigit()
                    .fixedSize()
                Spacer(minLength: 0)
            }

            // Tag chips
            if !vm.allTags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(vm.allTags.prefix(14), id: \.tag) { item in
                            let on = vm.filter.tags.contains(item.tag)
                            Button {
                                if on { vm.filter.tags.remove(item.tag) } else { vm.filter.tags.insert(item.tag) }
                            } label: {
                                Text("#\(item.tag)")
                                    .font(OmegaTheme.font(.meta, on ? .semibold : .regular))
                                    .foregroundColor(on ? theme.accentColor : theme.secondaryTextColor)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2.5)
                                    .background(
                                        Capsule().fill(on ? theme.accentColor.opacity(0.2) : theme.cardColor.opacity(0.5))
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(theme.cardColor.opacity(0.35))
    }

    func toggle(_ label: String, _ icon: String, _ binding: Binding<Bool>) -> some View {
        Button { binding.wrappedValue.toggle() } label: {
            HStack(spacing: 3) {
                Image(systemName: icon).font(OmegaTheme.font(.meta))
                Text(label).font(OmegaTheme.font(.meta, binding.wrappedValue ? .semibold : .regular))
                    .lineLimit(1)
            }
            .fixedSize()
            .foregroundColor(binding.wrappedValue ? theme.accentColor : theme.secondaryTextColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(binding.wrappedValue ? theme.accentColor.opacity(0.18) : theme.cardColor.opacity(0.5))
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(binding.wrappedValue ? [.isSelected] : [])
    }
}
