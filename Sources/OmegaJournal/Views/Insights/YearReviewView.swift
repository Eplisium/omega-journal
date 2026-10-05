import SwiftUI
import Charts
import AppKit
import OmegaJournalCore

// MARK: - Year in review

struct YearReviewView: View {
    @ObservedObject var vm: JournalViewModel
    @ObservedObject private var theme = ThemeManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var year: Int

    init(vm: JournalViewModel) {
        self.vm = vm
        _year = State(initialValue: vm.yearReviewYears.first ?? Calendar.current.component(.year, from: Date()))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Year", selection: $year) {
                    ForEach(vm.yearReviewYears, id: \.self) { Text(String($0)).tag($0) }
                }
                .frame(width: 120)
                Spacer()
                Button { exportPDF() } label: { Label("Export PDF", systemImage: "arrow.down.doc") }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(OmegaTheme.Spacing.l)
            Divider()
            ScrollView {
                YearReviewPage(review: vm.yearReview(year: year))
                    .padding(OmegaTheme.Spacing.xl)
            }
        }
        .frame(width: 720, height: 680)
        .background(theme.backgroundColor)
    }

    @MainActor
    private func exportPDF() {
        let review = vm.yearReview(year: year)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Year in Review \(year).pdf"
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try YearReviewExporter.writePDF(review: review, to: url)
            vm.showToast("Saved Year in Review \(year)")
        } catch {
            vm.showToast("Couldn't save PDF: \(error.localizedDescription)", isError: true)
        }
    }
}

/// The printable page. Fixed colour scheme so exported PDFs look identical on any theme.
struct YearReviewPage: View {
    let review: YearReview
    var printable = false
    @ObservedObject private var theme = ThemeManager.shared

    private var text: Color { printable ? Color(red: 0.13, green: 0.10, blue: 0.22) : theme.titleTextColor }
    private var secondary: Color { printable ? Color(red: 0.42, green: 0.38, blue: 0.52) : theme.secondaryTextColor }
    private var accent: Color { printable ? Color(red: 0.49, green: 0.30, blue: 0.93) : theme.accentColor }
    private let months = Calendar.current.shortMonthSymbols

    var body: some View {
        VStack(alignment: .leading, spacing: OmegaTheme.Spacing.xl) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Your \(String(review.year))").font(OmegaTheme.displayFont).foregroundColor(text)
                Text("A year of writing, in one page").font(OmegaTheme.bodyLargeFont).foregroundColor(secondary)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                stat("\(review.entryCount)", "entries")
                stat(review.totalWords.formatted(), "words")
                stat("\(review.writingDays)", "writing days")
                stat("\(review.longestStreak)", "day best streak")
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Entries per month").font(OmegaTheme.headingFont).foregroundColor(text)
                Chart(0..<12, id: \.self) { m in
                    BarMark(x: .value("Month", months[m]), y: .value("Entries", review.monthlyEntries[m]))
                        .foregroundStyle(accent.gradient).cornerRadius(3)
                }
                .frame(height: 140)
            }
            if let avg = review.averageMood {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Mood").font(OmegaTheme.headingFont).foregroundColor(text)
                    Text(String(format: "Average %.1f of 5", avg) + (review.bestMonth.map { " · brightest month: \(Calendar.current.monthSymbols[$0 - 1])" } ?? ""))
                        .font(OmegaTheme.bodyFont).foregroundColor(secondary)
                }
            }
            if !review.topTags.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Top tags").font(OmegaTheme.headingFont).foregroundColor(text)
                    Text(review.topTags.map { "#\($0.tag) (\($0.count))" }.joined(separator: "  ·  "))
                        .font(OmegaTheme.bodyFont).foregroundColor(secondary)
                }
            }
            if let title = review.longestEntryTitle {
                Text("Longest entry: “\(title)” — \(review.longestEntryWords.formatted()) words")
                    .font(OmegaTheme.bodyFont).foregroundColor(secondary)
            }
            if !review.favoriteTitles.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Favorites").font(OmegaTheme.headingFont).foregroundColor(text)
                    ForEach(review.favoriteTitles, id: \.self) { Text("★ \($0)").font(OmegaTheme.bodyFont).foregroundColor(secondary) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(OmegaTheme.font(.title, .bold, design: .rounded)).foregroundColor(accent)
            Text(label).font(OmegaTheme.metaFont).foregroundColor(secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: OmegaTheme.Radius.card).fill(accent.opacity(0.10)))
    }
}

enum YearReviewExporter {
    /// Renders the page to a single-page PDF with ImageRenderer. Local only.
    @MainActor
    static func writePDF(review: YearReview, to url: URL) throws {
        let page = YearReviewPage(review: review, printable: true)
            .padding(40)
            .frame(width: 612, alignment: .topLeading)
            .background(Color.white)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: page)
        var failure: Error?
        renderer.render { size, draw in
            var box = CGRect(origin: .zero, size: CGSize(width: 612, height: max(size.height, 792)))
            guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else {
                failure = CocoaError(.fileWriteUnknown); return
            }
            ctx.beginPDFPage(nil)
            ctx.translateBy(x: 0, y: box.height - size.height)
            draw(ctx)
            ctx.endPDFPage()
            ctx.closePDF()
        }
        if let failure { throw failure }
        guard FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileWriteUnknown) }
    }
}
