import SwiftUI

/// The last seven days against the four weeks before, as the Health app
/// lays out its highlights: two bars per measure, the recent one in colour,
/// and the change between them in a badge.
struct HighlightsCard: View {
    let stats: DictationStats

    var body: some View {
        StatsCard(title: "Faits marquants", symbol: "chart.line.uptrend.xyaxis", color: .primary) {
            VStack(alignment: .leading, spacing: 14) {
                HighlightRow(
                    title: "Mots par jour", symbol: "text.word.spacing", trend: stats.wordsPerDay,
                    color: StatsPalette.words, format: StatsFormat.count, unit: "mots"
                )
                Divider()
                HighlightRow(
                    title: "Dictées par jour", symbol: "mic.fill", trend: stats.dictationsPerDay,
                    color: StatsPalette.dictations, format: StatsFormat.count, unit: "dictées"
                )
                Divider()
                HighlightRow(
                    title: "Délai d'affichage", symbol: "timer", trend: stats.latency,
                    color: StatsPalette.latency, format: StatsFormat.seconds, unit: "s", lowerIsBetter: true
                )
                Divider()
                HighlightRow(
                    title: "Débit de parole", symbol: "speedometer", trend: stats.pace,
                    color: StatsPalette.pace, format: StatsFormat.count, unit: "mots/min"
                )
            }
        }
    }
}

private struct HighlightRow: View {
    let title: LocalizedStringKey
    let symbol: String
    let trend: DictationStats.Trend
    let color: Color
    let format: (Double) -> String
    let unit: String
    /// The wait shrinking is the good news: its badge turns green on the way down.
    var lowerIsBetter = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(color)
                Spacer()
                badge
            }
            ComparisonBar(label: "7 derniers jours", value: trend.recent, peak: peak, color: color, format: format, unit: unit)
            ComparisonBar(label: "4 semaines avant", value: trend.baseline, peak: peak, color: .gray, format: format, unit: unit)
        }
    }

    private var peak: Double { max(trend.recent ?? 0, trend.baseline ?? 0) }

    /// Green when the change is welcome, orange when it is not, grey when
    /// nothing moved.
    private func badgeTint(_ direction: DictationStats.Trend.Direction) -> Color {
        switch direction {
        case .steady: .secondary
        case .up: lowerIsBetter ? .orange : .green
        case .down: lowerIsBetter ? .green : .orange
        }
    }

    @ViewBuilder private var badge: some View {
        if let change = trend.change, let direction = trend.direction {
            let tint = badgeTint(direction)
            Text(change.formatted(.percent.precision(.fractionLength(0)).sign(strategy: .always())))
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(tint)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(tint.opacity(0.15), in: Capsule())
        } else {
            Text("Pas encore assez d'historique")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

/// One labelled bar, as long as its share of the tallest figure of the pair.
private struct ComparisonBar: View {
    let label: LocalizedStringKey
    let value: Double?
    let peak: Double
    let color: Color
    let format: (Double) -> String
    let unit: String

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            GeometryReader { geometry in
                Capsule()
                    .fill(color)
                    .frame(width: max(geometry.size.width * share, value == nil ? 0 : 3))
            }
            .frame(height: 12)
            Text(value.map { "\(format($0)) \(unit)" } ?? "—")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .frame(width: 100, alignment: .trailing)
        }
    }

    private var share: CGFloat {
        guard let value, peak > 0 else { return 0 }
        return CGFloat(value / peak)
    }
}
