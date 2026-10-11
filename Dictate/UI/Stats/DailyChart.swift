import Charts
import SwiftUI

/// What the daily charts share, after Shiori's reading chart: bars only, no
/// value axis, no gridlines, the figure above each column and its date below.
///
/// A month of labelled columns does not fit the window — "1 234" needs more
/// room than a thirtieth of the card — so the chart scrolls sideways, two
/// weeks at a time, opening on today.
enum DailyChart {
    static let barWidth: CGFloat = 14
    static let visibleDays = 14

    /// Columns are numbered 1 to 30, today last: a numeric axis keeps every
    /// column the same width, whatever its date.
    static func column(_ index: Int) -> Int { index + 1 }

    static func dayLabel(_ date: Date) -> some View {
        Text(date.formatted(.dateTime.day()))
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }

    /// Nine points: the figure has to fit between its neighbours. An empty
    /// day is left bare rather than labelled zero.
    @ViewBuilder
    static func valueLabel(_ text: String, visible: Bool = true) -> some View {
        if visible {
            Text(text)
                .font(.system(size: 9, design: .rounded))
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }

    /// The whole month on the axis, two weeks visible, opening on today;
    /// headroom above the tallest column for its label; a strip under the
    /// plot for the dates.
    struct Layout: ViewModifier {
        let peak: Double

        func body(content: Content) -> some View {
            content
                .chartXScale(domain: 0.5...(Double(DictationStats.dayCount) + 0.5))
                .chartYScale(domain: 0...max(peak * 1.25, 1))
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartScrollableAxes(.horizontal)
                .chartXVisibleDomain(length: DailyChart.visibleDays)
                .chartScrollPosition(initialX: Double(DictationStats.dayCount - DailyChart.visibleDays) + 0.5)
                .chartPlotStyle { plot in plot.padding(.bottom, 16) }
                .frame(height: 130)
                // The dates hang a few points past the frame.
                .padding(.bottom, 6)
        }
    }
}

/// Words, or dictations, per day over the last month.
struct DailyWordsCard: View {
    enum Metric: String, CaseIterable, Identifiable {
        case words, dictations
        var id: String { rawValue }

        var label: LocalizedStringKey {
            switch self {
            case .words: "Mots"
            case .dictations: "Dictées"
            }
        }

        var title: LocalizedStringKey {
            switch self {
            case .words: "Mots dictés"
            case .dictations: "Dictées"
            }
        }

        var color: Color {
            switch self {
            case .words: StatsPalette.words
            case .dictations: StatsPalette.dictations
            }
        }

        func value(_ day: DictationStats.Day) -> Int {
            switch self {
            case .words: day.words
            case .dictations: day.dictations
            }
        }
    }

    let days: [DictationStats.Day]
    @AppStorage("stats.chart.metric") private var metric: Metric = .words

    var body: some View {
        WidgetCard(title: metric.title) {
            Picker("Mesure", selection: $metric.animation(.snappy)) {
                ForEach(Metric.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                StatsFigure(
                    value: total.formatted(.number),
                    caption: metric == .words ? "mots en 30 jours" : "dictées en 30 jours",
                    color: metric.color
                )
                Chart(Array(days.enumerated()), id: \.element.id) { index, day in
                    BarMark(
                        x: .value("Jour", DailyChart.column(index)),
                        y: .value(metric == .words ? "Mots" : "Dictées", metric.value(day)),
                        width: .fixed(DailyChart.barWidth)
                    )
                    .foregroundStyle(metric.color)
                    .cornerRadius(3)
                    .annotation(position: .top, spacing: 2) {
                        DailyChart.valueLabel(metric.value(day).formatted(.number), visible: day.dictations > 0)
                    }
                    .annotation(position: .bottom, spacing: 4) { DailyChart.dayLabel(day.date) }
                }
                .modifier(DailyChart.Layout(peak: Double(days.map(metric.value).max() ?? 0)))
            }
        }
    }

    private var total: Int { days.reduce(0) { $0 + metric.value($1) } }
}

/// How long the text took to appear after `fn` was released, day by day:
/// Whisper stacked under Claude, the day's median total above its column.
struct DailyLatencyCard: View {
    let days: [DictationStats.Day]
    /// Median over the last seven days.
    let recent: Double?

    var body: some View {
        WidgetCard(title: "Délai d'affichage") {
            HStack(spacing: 12) {
                legend("Whisper", color: StatsPalette.whisper)
                legend("Claude", color: StatsPalette.claude)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                StatsFigure(
                    value: recent.map { "\(StatsFormat.seconds($0)) s" } ?? "—",
                    caption: "médiane sur 7 jours",
                    color: StatsPalette.whisper
                )
                Chart(Array(days.enumerated()), id: \.element.id) { index, day in
                    BarMark(
                        x: .value("Jour", DailyChart.column(index)),
                        y: .value("Whisper", day.transcription),
                        width: .fixed(DailyChart.barWidth)
                    )
                    .foregroundStyle(StatsPalette.whisper)
                    .annotation(position: .bottom, spacing: 4) { DailyChart.dayLabel(day.date) }
                    BarMark(
                        x: .value("Jour", DailyChart.column(index)),
                        y: .value("Claude", day.enhancement),
                        width: .fixed(DailyChart.barWidth)
                    )
                    .foregroundStyle(StatsPalette.claude)
                    .annotation(position: .top, spacing: 2) {
                        DailyChart.valueLabel(
                            StatsFormat.seconds(day.transcription + day.enhancement),
                            visible: day.dictations > 0
                        )
                    }
                }
                .modifier(DailyChart.Layout(peak: days.map { $0.transcription + $0.enhancement }.max() ?? 0))
            }
        }
    }

    private func legend(_ title: LocalizedStringKey, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title)
        }
    }
}
