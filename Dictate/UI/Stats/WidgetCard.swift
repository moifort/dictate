import SwiftUI

/// The rounded card every statistic sits in, titled the way the Fitness app
/// titles its cards. Taken from Shiori's dashboard, with macOS colours.
struct WidgetCard<Content: View, Accessory: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let accessory: Accessory
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.headline)
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

extension WidgetCard where Accessory == EmptyView {
    init(title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title
        self.accessory = EmptyView()
        self.content = content()
    }
}

/// The Fitness-like colours of the statistics. System colours, so they keep
/// their contrast in light and dark appearance alike; each one means one thing.
enum StatsPalette {
    static let words = Color.pink
    static let dictations = Color.green
    static let whisper = Color.cyan
    static let claude = Color.purple
    static let pace = Color.orange
}

/// One big rounded figure and what it counts, as on top of every card.
struct StatsFigure: View {
    let value: String
    let caption: LocalizedStringKey
    let color: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(value)
                .font(.system(.title, design: .rounded, weight: .bold))
                .foregroundStyle(color)
            Text(caption)
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .contentTransition(.numericText())
    }
}

enum StatsFormat {
    static func seconds(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)))
    }

    static func count(_ value: Double) -> String {
        Int(value.rounded()).formatted(.number)
    }
}
