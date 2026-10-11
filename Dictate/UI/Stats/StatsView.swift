import SwiftUI

/// The statistics window: today at a glance, the last month day by day, and
/// how this week compares with the four before.
struct StatsView: View {
    let history: DictationHistory

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
                        description: Text("Maintenez fn et parlez : vos statistiques apparaîtront ici.")
                    )
                } else {
                    ScrollView {
                        VStack(spacing: 12) {
                            TodayCard(day: stats.today)
                            DailyWordsCard(days: stats.days)
                            DailyLatencyCard(records: history.records, now: context.date)
                            TrendsCard(stats: stats)
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

/// Three figures side by side, as the Fitness summary opens.
struct TodayCard: View {
    let day: DictationStats.Day

    var body: some View {
        WidgetCard(title: "Aujourd'hui") {
            HStack(alignment: .top) {
                figure(day.words.formatted(.number), "mots", StatsPalette.words)
                Spacer()
                figure(day.dictations.formatted(.number), "dictées", StatsPalette.dictations)
                Spacer()
                figure(day.dictations > 0 ? "\(StatsFormat.seconds(day.latency)) s" : "—", "délai médian", StatsPalette.whisper)
            }
        }
    }

    private func figure(_ value: String, _ caption: LocalizedStringKey, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .foregroundStyle(color)
                .contentTransition(.numericText())
            Text(caption)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}
