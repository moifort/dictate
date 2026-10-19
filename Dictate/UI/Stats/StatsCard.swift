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
            // One height whatever the accessory, so cards side by side line up.
            HStack {
                Label(title, systemImage: symbol)
                    .font(.headline)
                    .foregroundStyle(color)
                Spacer()
                accessory
            }
            .frame(height: 22)
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
    /// The figure, one number per unit: "4 h 36 min" is two of them.
    let parts: [(value: String, unit: LocalizedStringKey)]
    let range: String

    init(caption: LocalizedStringKey, value: String, unit: LocalizedStringKey, range: String) {
        self.init(caption: caption, parts: [(value, unit)], range: range)
    }

    init(caption: LocalizedStringKey, parts: [(value: String, unit: LocalizedStringKey)], range: String) {
        self.caption = caption
        self.parts = parts
        self.range = range
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(caption)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                ForEach(parts.indices, id: \.self) { index in
                    Text(parts[index].value)
                        .font(.system(.title, design: .rounded, weight: .bold))
                        .contentTransition(.numericText())
                    Text(parts[index].unit)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
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
    static let apple = Color.blue
    static let pace = Color.orange
    static let timeSaved = Color.indigo

    /// The colour of each model's cleanup time in the delay chart.
    static func color(for reviewer: Reviewer) -> Color {
        switch reviewer {
        case .claude: claude
        case .apple: apple
        case .none: latency
        }
    }
}

enum StatsFormat {
    static func seconds(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)))
    }

    static func count(_ value: Double) -> String {
        Int(value.rounded()).formatted(.number)
    }

    /// A time saved as a clock reads it: seconds under a minute, minutes under
    /// an hour, then hours and minutes, never a fraction of an hour. A loss
    /// reads as nothing saved.
    static func duration(_ seconds: TimeInterval) -> [(value: String, unit: String)] {
        let seconds = Int(max(0, seconds).rounded())
        if seconds < 60 { return [(seconds.formatted(.number), "s")] }
        let minutes = Int((Double(seconds) / 60).rounded())
        if minutes < 60 { return [(minutes.formatted(.number), "min")] }
        let hours = [((minutes / 60).formatted(.number), "h")]
        return minutes % 60 == 0 ? hours : hours + [((minutes % 60).formatted(.number), "min")]
    }

    /// The same, in a line: "4 h 36 min".
    static func durationText(_ seconds: TimeInterval) -> String {
        duration(seconds).map { "\($0.value) \($0.unit)" }.joined(separator: " ")
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
