import Foundation
import SwiftUI
import Testing
@testable import OmegaJournal

@Suite("Shell navigation")
struct ShellNavigationTests {
    @Test("sidebar selection round-trips through its storage key")
    func storageKeyRoundTrip() {
        let items: [SidebarItem] = [.today, .all, .favorites, .thisWeek, .insights, .calendar,
                                    .onThisDay, .archive, .trash, .mood(.good), .tag("work:deep")]
        for item in items {
            #expect(SidebarItem(storageKey: item.storageKey) == item)
        }
    }

    @Test("hidden is never restored and unknown keys are rejected")
    func hiddenNotRestored() {
        #expect(SidebarItem(storageKey: SidebarItem.hidden.storageKey) == .all)
        #expect(SidebarItem(storageKey: "bogus") == nil)
        #expect(SidebarItem(storageKey: "mood:99") == nil)
        #expect(SidebarItem(storageKey: "tag:") == nil)
    }

    @Test("keyboard stepping clamps and handles empty or unknown selection")
    func stepping() {
        let ids = ["a", "b", "c"]
        #expect(ShellEntryNavigation.step(1, from: "a", in: ids) == "b")
        #expect(ShellEntryNavigation.step(-1, from: "a", in: ids) == "a")
        #expect(ShellEntryNavigation.step(1, from: "c", in: ids) == "c")
        #expect(ShellEntryNavigation.step(1, from: nil, in: ids) == "a")
        #expect(ShellEntryNavigation.step(-1, from: "zzz", in: ids) == "c")
        #expect(ShellEntryNavigation.step(1, from: "a", in: []) == nil)
    }

    @Test("drop import accepts only local markdown files")
    func dropFilter() {
        let urls = [URL(fileURLWithPath: "/tmp/a.md"), URL(fileURLWithPath: "/tmp/b.MARKDOWN"),
                    URL(fileURLWithPath: "/tmp/c.txt"), URL(string: "https://x.com/d.md")!]
        #expect(ShellImportFilter.markdownFiles(in: urls).map(\.lastPathComponent) == ["a.md", "b.MARKDOWN"])
    }

    @MainActor
    @Test("on-accent color is dark on light accents and white on dark accents")
    func onAccent() {
        #expect(ThemeManager.onAccent(for: Color(red: 1, green: 0.95, blue: 0.4)) == .black)
        #expect(ThemeManager.onAccent(for: Color(red: 0.3, green: 0.1, blue: 0.7)) == .white)
    }

    @Test("resign-active lock preference defaults to on")
    func lockPrefDefault() {
        #expect(ShellPrefs.lockOnResignKey == "shell.lockHiddenOnResignActive")
    }
}

@Suite("Shell quick capture and reading prefs")
struct ShellQuickCaptureTests {
    @Test("quick capture trims and rejects blank text")
    func normalize() {
        #expect(QuickCapture.normalized("  hello \n") == "hello")
        #expect(QuickCapture.normalized(" \n\t ") == nil)
        #expect(QuickCapture.normalized("") == nil)
    }

    @Test("reading width clamps and falls back to the default")
    func width() {
        #expect(ReadingPreferences.clampedWidth(0) == ReadingPreferences.defaultMaxWidth)
        #expect(ReadingPreferences.clampedWidth(.nan) == ReadingPreferences.defaultMaxWidth)
        #expect(ReadingPreferences.clampedWidth(100) == ReadingPreferences.widthRange.lowerBound)
        #expect(ReadingPreferences.clampedWidth(5000) == ReadingPreferences.widthRange.upperBound)
        #expect(ReadingPreferences.clampedWidth(800) == 800)
    }

    @Test("reading font design maps stored values, unknown falls back")
    func design() {
        #expect(ReadingPreferences.fontDesign(from: "serif") == .serif)
        #expect(ReadingPreferences.fontDesign(from: "monospaced") == .monospaced)
        #expect(ReadingPreferences.fontDesign(from: "nonsense") == .default)
        #expect(ReadingPreferences.maxWidthKey == "readingMaxWidth")
        #expect(ReadingPreferences.fontDesignKey == "readingFontDesign")
    }
}
