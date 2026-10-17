import SwiftUI

/// The last seven days against the four weeks before, as the Fitness app
/// shows its trends: one tile per measure with the recent figure, an arrow
/// for the direction, and the change in a badge.
struct HighlightsCard: View {
    let stats: DictationStats

    var body: some View {
        StatsCard(title: "Tendances", symbol: "chart.line.uptrend.xyaxis", color: .primary) {
            Text("7 derniers jours contre les 4 semaines d'avant")
                .font(.caption)
                .foregroundStyle(.secondary)
        } content: {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 10, alignment: .top)], spacing: 10) {
                TrendTile(
                    title: "Mots par jour", symbol: "text.word.spacing", trend: stats.wordsPerDay,
                    color: StatsPalette.words, format: StatsFormat.count, unit: String(localized: "mots")
                )
                TrendTile(
                    title: "Dictées par jour", symbol: "mic.fill", trend: stats.dictationsPerDay,
                    color: StatsPalette.dictations, format: StatsFormat.count, unit: String(localized: "dictées")
                )
                TrendTile(
                    title: "Délai d'affichage", symbol: "timer", trend: stats.latency,
                    color: StatsPalette.latency, format: StatsFormat.seconds, unit: "s", lowerIsBetter: true
                )
                TrendTile(
                    title: "Débit de parole", symbol: "speedometer", trend: stats.pace,
                    color: StatsPalette.pace, format: StatsFormat.count, unit: String(localized: "mots/min")
                )
            }
        }
    }
}

private struct TrendTile: View {
    let title: LocalizedStringKey
    let symbol: String
    let trend: DictationStats.Trend
    let color: Color
    let format: (Double) -> String
    let unit: String
    /// The wait shrinking is the good news: its arrow turns green on the way down.
    var lowerIsBetter = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(trend.recent.map(format) ?? "—")
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .contentTransition(.numericText())
                Text(unit)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: arrow)
                    .font(.title2)
                    .foregroundStyle(tint)
            }
            footer
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12))
    }

    @ViewBuilder private var footer: some View {
        if let change = trend.change, let baseline = trend.baseline {
            HStack(spacing: 6) {
                Text(change.formatted(.percent.precision(.fractionLength(0)).sign(strategy: .always())))
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(tint.opacity(0.15), in: Capsule())
                Text("contre \(format(baseline)) \(unit) avant")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } else {
            Text("Pas encore assez d'historique")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var arrow: String {
        switch trend.direction {
        case .up: "arrow.up.right.circle.fill"
        case .down: "arrow.down.right.circle.fill"
        case .steady: "arrow.right.circle.fill"
        case nil: "circle.dashed"
        }
    }

    /// Green when the change is welcome, orange when it is not, grey when
    /// nothing moved or nothing compares yet.
    private var tint: Color {
        switch trend.direction {
        case .up: lowerIsBetter ? .orange : .green
        case .down: lowerIsBetter ? .green : .orange
        case .steady, nil: .secondary
        }
    }
}
