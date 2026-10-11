import SwiftUI

/// The Fitness app's trends: the last seven days against the four weeks
/// before, one arrow per measure. Only a change past five percent turns the
/// arrow; a measure without four weeks of history behind it waits.
struct TrendsCard: View {
    let stats: DictationStats

    var body: some View {
        WidgetCard(title: "Tendances") {
            VStack(alignment: .leading, spacing: 14) {
                Text("7 derniers jours comparés aux 4 semaines précédentes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 16) {
                    GridRow {
                        TrendRow(
                            title: "Mots par jour", trend: stats.wordsPerDay, color: StatsPalette.words,
                            format: StatsFormat.count, unit: "mots"
                        )
                        TrendRow(
                            title: "Dictées par jour", trend: stats.dictationsPerDay, color: StatsPalette.dictations,
                            format: StatsFormat.count, unit: "dictées"
                        )
                    }
                    GridRow {
                        TrendRow(
                            title: "Délai d'affichage", trend: stats.latency, color: StatsPalette.whisper,
                            format: StatsFormat.seconds, unit: "s", lowerIsBetter: true
                        )
                        TrendRow(
                            title: "Débit de parole", trend: stats.pace, color: StatsPalette.pace,
                            format: StatsFormat.count, unit: "mots/min"
                        )
                    }
                }
            }
        }
    }
}

private struct TrendRow: View {
    let title: LocalizedStringKey
    let trend: DictationStats.Trend
    let color: Color
    let format: (Double) -> String
    let unit: String
    /// The wait shrinking is the good news: its arrow points down in colour.
    var lowerIsBetter = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(arrowColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(trend.recent.map { "\(format($0)) \(unit)" } ?? "—")
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .foregroundStyle(color)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var symbol: String {
        switch trend.direction {
        case .up: "arrow.up.circle.fill"
        case .down: "arrow.down.circle.fill"
        case .steady: "equal.circle.fill"
        case nil: "circle.dashed"
        }
    }

    private var arrowColor: Color {
        switch trend.direction {
        case .up: lowerIsBetter ? .orange : color
        case .down: lowerIsBetter ? color : .orange
        case .steady, nil: .secondary
        }
    }

    private var caption: String {
        guard let baseline = trend.baseline else { return String(localized: "Pas encore assez d'historique") }
        return String(localized: "contre \(format(baseline)) \(unit)")
    }
}
