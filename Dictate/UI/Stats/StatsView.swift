import SwiftUI

/// The statistics window, laid out as the Health app lays out a measure: a
/// period picker pinned on top, one card per measure with its figure and
/// chart, and the highlights of the week at the bottom.
struct StatsView: View {
    let history: DictationHistory
    @AppStorage("stats.period") private var period: StatsPeriod = .week
    @State private var statsMemo = Memo<StatsKey, DictationStats>()
    @State private var seriesMemo = Memo<StatsKey, DictationSeries>()

    var body: some View {
        // Read on every change of the history, and again past midnight
        // through the timeline, so "today" never goes stale. Worked out
        // again only when the history, the period or the hour changed.
        TimelineView(.everyMinute) { context in
            let key = StatsKey(records: history.records, period: period, now: context.date)
            let stats = statsMemo.value(for: key) { DictationStats(records: history.records, now: context.date) }
            Group {
                if stats.isEmpty {
                    ContentUnavailableView(
                        "Aucune dictée pour l'instant",
                        systemImage: "chart.bar",
                        description: Text("Maintenez la touche de dictée et parlez : vos statistiques apparaîtront ici.")
                    )
                } else {
                    let series = seriesMemo.value(for: key) {
                        DictationSeries(records: history.records, period: period, now: context.date)
                    }
                    ScrollView {
                        VStack(spacing: 12) {
                            // First and across the whole window: the figure
                            // looked at most, after each change of model.
                            LatencyCard(records: history.records, period: period, now: context.date)
                            // What all the other figures add up to.
                            TimeSavedCard(series: series, total: stats.timeSaved)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 400), spacing: 12, alignment: .top)], spacing: 12) {
                                WordsCard(series: series)
                                DictationsCard(series: series)
                                PaceCard(series: series)
                            }
                            HighlightsCard(stats: stats)
                        }
                        .padding(16)
                    }
                    // Pinned above the scroll view: the cards slide under it
                    // and the bar material keeps it legible.
                    .safeAreaInset(edge: .top, spacing: 0) {
                        Picker("Période", selection: $period.animation(.snappy)) {
                            ForEach(StatsPeriod.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        // Span the whole window so the material covers the
                        // cards on both sides of the picker too.
                        .frame(maxWidth: .infinity)
                        .background(.bar)
                    }
                }
            }
        }
        .frame(minWidth: 520, minHeight: 480)
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

extension StatsPeriod {
    /// The segments of the picker, spelled out in words rather than
    /// lettered or numbered.
    fileprivate var label: LocalizedStringKey {
        switch self {
        case .day: "Jour"
        case .week: "Semaine"
        case .month: "Mois"
        case .sixMonths: "Six mois"
        case .year: "Année"
        }
    }
}
