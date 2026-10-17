import Charts
import SwiftUI

/// Words dictated over the period, one column per unit of time.
struct WordsCard: View {
    let series: DictationSeries

    var body: some View {
        StatsCard(title: "Mots dictés", symbol: "text.word.spacing", color: StatsPalette.words) {
            MetricHeadline(
                caption: "Total", value: series.words.formatted(.number), unit: "mots",
                range: StatsFormat.range(series)
            )
            PeriodChart(
                series: series,
                peak: Double(series.buckets.map(\.words).max() ?? 0),
                floor: 100,
                value: { $0.dictations > 0 ? String(localized: "\($0.words.formatted(.number)) mots") : nil }
            ) { bucket, dimmed in
                BarMark(
                    x: .value("Date", bucket.date, unit: series.period.unit),
                    y: .value("Mots", bucket.words)
                )
                .foregroundStyle(StatsPalette.words)
                .opacity(dimmed ? 0.4 : 1)
                .cornerRadius(3)
            }
        }
    }
}

/// Dictations over the period.
struct DictationsCard: View {
    let series: DictationSeries

    var body: some View {
        StatsCard(title: "Dictées", symbol: "mic.fill", color: StatsPalette.dictations) {
            MetricHeadline(
                caption: "Total", value: series.dictations.formatted(.number), unit: "dictées",
                range: StatsFormat.range(series)
            )
            PeriodChart(
                series: series,
                peak: Double(series.buckets.map(\.dictations).max() ?? 0),
                floor: 10,
                value: { $0.dictations > 0 ? String(localized: "\($0.dictations) dictées") : nil }
            ) { bucket, dimmed in
                BarMark(
                    x: .value("Date", bucket.date, unit: series.period.unit),
                    y: .value("Dictées", bucket.dictations)
                )
                .foregroundStyle(StatsPalette.dictations)
                .opacity(dimmed ? 0.4 : 1)
                .cornerRadius(3)
            }
        }
    }
}

/// How long the text took to appear after `fn` was released, with the
/// current engine only: Whisper's dictations were several times slower and
/// would drown its median. The engine's time is stacked under Claude's.
struct LatencyCard: View {
    let records: [DictationRecord]
    let period: StatsPeriod
    let now: Date

    private let engine = TranscriptionEngine.parakeet

    var body: some View {
        let series = DictationSeries(records: records.filter { $0.engine == engine }, period: period, now: now)
        StatsCard(title: "Délai d'affichage", symbol: "timer", color: StatsPalette.latency) {
            // The legend shares the headline's row: a row of its own would
            // make this card taller than its neighbours.
            HStack(alignment: .bottom) {
                MetricHeadline(
                    caption: "Médiane", value: series.latency.map(StatsFormat.seconds) ?? "—", unit: "s",
                    range: StatsFormat.range(series)
                )
                Spacer()
                HStack(spacing: 12) {
                    legend(engine.displayName, color: StatsPalette.latency)
                    legend("Claude", color: StatsPalette.claude)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            PeriodChart(
                series: series,
                peak: series.buckets.map { $0.transcription + $0.enhancement }.max() ?? 0,
                floor: 1,
                value: { $0.dictations > 0 ? "\(StatsFormat.seconds($0.transcription + $0.enhancement)) s" : nil }
            ) { bucket, dimmed in
                BarMark(
                    x: .value("Date", bucket.date, unit: series.period.unit),
                    y: .value("Transcription", bucket.transcription)
                )
                .foregroundStyle(StatsPalette.latency)
                .opacity(dimmed ? 0.4 : 1)
                BarMark(
                    x: .value("Date", bucket.date, unit: series.period.unit),
                    y: .value("Claude", bucket.enhancement)
                )
                .foregroundStyle(StatsPalette.claude)
                .opacity(dimmed ? 0.4 : 1)
            }
        }
    }

    private func legend(_ title: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title)
        }
    }
}

/// Words per minute of speech over the period.
struct PaceCard: View {
    let series: DictationSeries

    var body: some View {
        StatsCard(title: "Débit de parole", symbol: "speedometer", color: StatsPalette.pace) {
            MetricHeadline(
                caption: "Moyenne", value: series.pace.map(StatsFormat.count) ?? "—", unit: "mots/min",
                range: StatsFormat.range(series)
            )
            PeriodChart(
                series: series,
                peak: series.buckets.compactMap(\.pace).max() ?? 0,
                floor: 100,
                value: { $0.pace.map { String(localized: "\(StatsFormat.count($0)) mots/min") } }
            ) { bucket, dimmed in
                BarMark(
                    x: .value("Date", bucket.date, unit: series.period.unit),
                    y: .value("Mots par minute", bucket.pace ?? 0)
                )
                .foregroundStyle(StatsPalette.pace)
                .opacity(dimmed ? 0.4 : 1)
                .cornerRadius(3)
            }
        }
    }
}
