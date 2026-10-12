import SwiftUI

/// The rounded card every statistic sits in, titled the way the Health app
/// titles its cards: a symbol and the name of the measure in its colour.
struct StatsCard<Content: View, Accessory: View>: View {
    let title: LocalizedStringKey
    let symbol: String
    let color: Color
    @ViewBuilder let accessory: Accessory
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(title, systemImage: symbol)
                    .font(.headline)
                    .foregroundStyle(color)
                Spacer()
                accessory
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 16))
    }
}

extension StatsCard where Accessory == EmptyView {
    init(title: LocalizedStringKey, symbol: String, color: Color, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.color = color
        self.accessory = EmptyView()
        self.content = content()
    }
}

/// What a Health chart says above its columns: the kind of figure in small
/// capitals, the figure itself with its unit, and the dates it covers.
struct MetricHeadline: View {
    let caption: LocalizedStringKey
    let value: String
    let unit: LocalizedStringKey
    let range: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(caption)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(.title, design: .rounded, weight: .bold))
                    .contentTransition(.numericText())
                Text(unit)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(range)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// The Health-like colours of the statistics. System colours, so they keep
/// their contrast in light and dark appearance alike; each one means one thing.
enum StatsPalette {
    static let words = Color.pink
    static let dictations = Color.green
    static let latency = Color.cyan
    static let claude = Color.purple
    static let pace = Color.orange
}

enum StatsFormat {
    static func seconds(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)))
    }

    static func count(_ value: Double) -> String {
        Int(value.rounded()).formatted(.number)
    }

    /// The dates a series covers, under its headline figure, up to today: the
    /// current week or month is not over yet.
    static func range(_ series: DictationSeries, now: Date = .now) -> String {
        let last = min(series.end.addingTimeInterval(-1), now)
        switch series.period {
        case .day: return series.start.formatted(.dateTime.weekday(.wide).day().month(.wide))
        case .week, .month, .sixMonths: return (series.start..<last).formatted(.interval.day().month(.abbreviated).year())
        case .year: return (series.start..<last).formatted(.interval.month(.abbreviated).year())
        }
    }

    /// The column under the pointer, in the lollipop.
    static func label(_ bucket: DictationSeries.Bucket, in period: StatsPeriod) -> String {
        let last = bucket.end.addingTimeInterval(-1)
        switch period {
        case .day: return (bucket.date..<bucket.end).formatted(.interval.hour().minute())
        case .week, .month: return bucket.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        case .sixMonths: return (bucket.date..<last).formatted(.interval.day().month(.abbreviated))
        case .year: return bucket.date.formatted(.dateTime.month(.wide).year())
        }
    }
}
