import SwiftUI

/// The statistics window, laid out as the Health app lays out a measure: a
/// period picker on top, one card per measure with its figure and chart,
/// and the highlights of the week at the bottom.
struct StatsView: View {
    let history: DictationHistory
    @AppStorage("stats.period") private var period: StatsPeriod = .week

    var body: some View {
        // Read on every change of the history, and again past midnight
        // through the timeline, so "today" never goes stale.
        TimelineView(.everyMinute) { context in
            let stats = DictationStats(records: history.records, now: context.date)
            Group {
                if stats.isEmpty {
                    ContentUnavailableView(
                        "Aucune dictée pour l'instant",
                        systemImage: "chart.bar",
                        description: Text("Maintenez la touche de dictée et parlez : vos statistiques apparaîtront ici.")
                    )
                } else {
                    let series = DictationSeries(records: history.records, period: period, now: context.date)
                    ScrollView {
                        VStack(spacing: 12) {
                            Picker("Période", selection: $period.animation(.snappy)) {
                                ForEach(StatsPeriod.allCases) { Text($0.label).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .padding(.bottom, 4)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 400), spacing: 12, alignment: .top)], spacing: 12) {
                                WordsCard(series: series)
                                DictationsCard(series: series)
                                LatencyCard(records: history.records, period: period, now: context.date)
                                PaceCard(series: series)
                            }
                            HighlightsCard(stats: stats)
                        }
                        .padding(16)
                    }
                }
            }
        }
        .frame(minWidth: 520, minHeight: 480)
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

private extension StatsPeriod {
    /// The segments of the picker, as the Health app letters them.
    var label: LocalizedStringKey {
        switch self {
        case .day: "J"
        case .week: "S"
        case .month: "M"
        case .sixMonths: "6M"
        case .year: "A"
        }
    }
}
