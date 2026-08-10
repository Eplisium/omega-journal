import SwiftUI
import Charts

// MARK: - Mood Trend Chart

struct MoodTrendChartView: View {
    let data: [MoodPoint]
    var body: some View {
        if data.isEmpty {
            emptyChart("No mood data yet — start writing!")
        } else {
            Chart(data) { point in
                LineMark(x: .value("Date", point.date), y: .value("Mood", point.avg))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(Color.accentColor.gradient)
                    .symbol(Circle().strokeBorder(lineWidth: 1))
                    .symbolSize(24)
                RuleMark(y: .value("Neutral", 3.0))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(Color.secondary.opacity(0.35))
            }
            .chartYScale(domain: 1...5)
            .chartYAxis {
                AxisMarks(values: [1, 2, 3, 4, 5]) { v in
                    AxisGridLine().foregroundStyle(Color.secondary.opacity(0.1))
                    AxisValueLabel {
                        let label = [1: "😞", 2: "😕", 3: "😐", 4: "🙂", 5: "😄"][v.as(Int.self) ?? 3] ?? ""
                        Text(label).font(.system(size: 10))
                    }
                }
            }
            .frame(height: 180)
        }
    }
}

// MARK: - Mood Distribution Chart

struct MoodDistributionView: View {
    let data: [MoodCount]
    var body: some View {
        if data.allSatisfy({ $0.count == 0 }) {
            emptyChart("No mood data yet — start writing!")
        } else {
            Chart(data) { item in
                BarMark(x: .value("Mood", item.mood.label), y: .value("Count", item.count))
                    .foregroundStyle(item.mood.color.gradient)
                    .cornerRadius(4)
                if item.count > 0 {
                    RuleMark(y: .value("Count", item.count))
                        .foregroundStyle(.clear)
                        .annotation(position: .top) {
                            Text("\(item.count)").font(.system(size: 10, weight: .medium)).foregroundColor(.secondary)
                        }
                }
            }
            .frame(height: 150)
            .chartYAxis { AxisMarks(position: .leading) }
        }
    }
}

// MARK: - Empty Chart Placeholder

func emptyChart(_ message: String) -> some View {
    HStack {
        Spacer()
        VStack(spacing: 8) {
            Image(systemName: "chart.line.uptrend.xyaxis").font(.system(size: 28)).foregroundColor(.secondary.opacity(0.5))
            Text(message).font(.system(size: 13)).foregroundColor(.secondary)
        }
        .padding(.vertical, 30)
        Spacer()
    }
}
