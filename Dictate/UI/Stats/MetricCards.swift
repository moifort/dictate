import Charts
import SwiftUI

/// The time dictating saved over typing the same words, over the period and
/// since the first dictation.
struct TimeSavedCard: View {
    let series: DictationSeries
    /// Seconds saved since the first dictation.
    let total: TimeInterval

    var body: some View {
        let period = StatsFormat.duration(series.timeSaved)
        let overall = StatsFormat.duration(total)
        StatsCard(title: "Temps gagné", symbol: "hourglass", color: StatsPalette.timeSaved) {
            Text("Depuis le début : \(overall.value) \(overall.unit)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
        } content: {
            MetricHeadline(
                caption: "Total", value: period.value, unit: LocalizedStringKey(period.unit),
                range: StatsFormat.range(series)
            )
            PeriodChart(
                series: series,
                peak: series.buckets.map(\.timeSaved).max() ?? 0,
                floor: 10,
                value: { bucket in
                    guard bucket.dictations > 0 else { return nil }
                    let saved = StatsFormat.duration(bucket.timeSaved)
                    return "\(saved.value) \(saved.unit)"
                }
            ) { bucket, dimmed in
                BarMark(
                    x: .value("Date", bucket.date, unit: series.period.unit),
                    y: .value("Minutes", max(0, bucket.timeSaved) / 60)
                )
                .foregroundStyle(StatsPalette.timeSaved)
                .opacity(dimmed ? 0.4 : 1)
                .cornerRadius(3)
            }
            Text("Par rapport à une frappe au clavier à \(Int(DictationRecord.typingPace)) mots/min, temps de parole et d'attente déduits.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

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
/// would drown its median. The cleanup's time is stacked over the engine's,
/// coloured by the model that did it: a day offline shows Apple Intelligence
/// where Claude usually is. A column where both worked splits its cleanup
/// time between them, in the proportion of the dictations each took.
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
                    ForEach(series.reviewers) { reviewer in
                        legend(reviewer.displayName, color: StatsPalette.color(for: reviewer))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            PeriodChart(
                series: series,
                peak: series.buckets.map { $0.transcription + $0.enhancement }.max() ?? 0,
                floor: 1,
                value: { $0.dictations > 0 ? Self.label($0) : nil }
            ) { bucket, dimmed in
                // Without a model, what is left of the cleanup time is the
                // paste alone: it stays with the engine rather than vanishing.
                BarMark(
                    x: .value("Date", bucket.date, unit: series.period.unit),
                    y: .value("Transcription", bucket.transcription + (bucket.reviewers.isEmpty ? bucket.enhancement : 0))
                )
                .foregroundStyle(StatsPalette.latency)
                .opacity(dimmed ? 0.4 : 1)
                ForEach(series.reviewers) { reviewer in
                    BarMark(
                        x: .value("Date", bucket.date, unit: series.period.unit),
                        y: .value(reviewer.displayName, bucket.enhancement * bucket.share(of: reviewer))
                    )
                    .foregroundStyle(StatsPalette.color(for: reviewer))
                    .opacity(dimmed ? 0.4 : 1)
                }
            }
        }
    }

    /// The column's wait, and the model behind it: named alone when it did
    /// every cleanup, with its share when the column mixes two.
    static func label(_ bucket: DictationSeries.Bucket) -> String {
        let seconds = "\(StatsFormat.seconds(bucket.transcription + bucket.enhancement)) s"
        let used = Reviewer.allCases.filter { bucket.reviewers[$0, default: 0] > 0 }
        switch used.count {
        case 0: return seconds
        case 1: return "\(seconds) · \(used[0].displayName)"
        default:
            let shares = used.map { reviewer in
                "\(reviewer.displayName) \(bucket.share(of: reviewer).formatted(.percent.precision(.fractionLength(0))))"
            }
            return "\(seconds) · \(shares.joined(separator: ", "))"
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
