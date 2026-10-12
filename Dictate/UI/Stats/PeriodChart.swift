import Charts
import SwiftUI

/// What the charts share, after the Health app: columns sized by their unit
/// of time, so the whole period fills the card whatever its width; the value
/// axis on the right with its gridlines; a few dates below; and a lollipop
/// under the pointer for an exact figure.
///
/// No figure above the columns: a month of them never fit the window, which
/// is what used to make the charts scroll sideways.
struct PeriodChart<Marks: ChartContent>: View {
    let series: DictationSeries
    /// The tallest column, to keep the value axis honest when every column is empty.
    let peak: Double
    /// The top of the value axis when the period is empty.
    let floor: Double
    /// What the lollipop reads for a column; nil reads as no dictation.
    let value: (DictationSeries.Bucket) -> String?
    /// The marks of one column; `dimmed` while the pointer rests on another.
    @ChartContentBuilder let marks: (_ bucket: DictationSeries.Bucket, _ dimmed: Bool) -> Marks

    @State private var hovered: Date?

    var body: some View {
        let selected = hovered.flatMap(series.bucket(containing:))
        let chart = Chart {
            ForEach(series.buckets) { bucket in
                marks(bucket, selected != nil && selected != bucket)
            }
            if let selected {
                RuleMark(x: .value("Date", selected.midpoint))
                    .foregroundStyle(.tertiary)
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(
                        position: .top, spacing: 4,
                        overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                    ) {
                        Lollipop(value: value(selected), date: StatsFormat.label(selected, in: series.period))
                    }
            }
        }
        .chartXSelection(value: $hovered)
        .chartXScale(domain: series.start...series.end)
        .chartXAxis {
            AxisMarks(values: axisDates) {
                AxisValueLabel(format: series.period.axisFormat)
                    .font(.caption2)
                    .foregroundStyle(Color.secondary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) {
                AxisGridLine()
                AxisValueLabel()
                    .font(.caption2)
                    .foregroundStyle(Color.secondary)
            }
        }
        .frame(height: 150)
        // Headroom for the lollipop above the tallest column: the annotation
        // may overflow the plot, and lands in this margin.
        .padding(.top, 40)
        if peak > 0 {
            chart.chartYScale(domain: .automatic(includesZero: true))
        } else {
            chart.chartYScale(domain: 0...floor)
        }
    }

    /// Where a date goes under the columns. A week or a year names every
    /// column, so the label sits under its middle; the day, the month and
    /// the six months mark a scale, so the label sits at the tick.
    private var axisDates: [Date] {
        let starts = series.buckets.map(\.date)
        switch series.period {
        case .day: return stride(from: 0, to: starts.count, by: 6).map { starts[$0] }
        case .week, .year: return series.buckets.map(\.midpoint)
        case .month: return stride(from: 0, to: starts.count, by: 7).map { starts[$0] }
        case .sixMonths:
            let calendar = Calendar.current
            var dates: [Date] = []
            var date = calendar.dateInterval(of: .month, for: series.start)!.end
            while date < series.end {
                dates.append(date)
                date = calendar.date(byAdding: .month, value: 1, to: date)!
            }
            return dates
        }
    }
}

/// The figure under the pointer and the column it belongs to, floating above
/// the chart as in the Health app.
private struct Lollipop: View {
    let value: String?
    let date: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value ?? String(localized: "Aucune dictée"))
                .font(.system(.callout, design: .rounded, weight: .semibold))
            Text(date)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: .rect(cornerRadius: 8))
        .shadow(color: .black.opacity(0.15), radius: 4, y: 1)
    }
}

/// How the dates read under each period. The seven columns of a week are
/// wide enough for "lun."; the twelve of a year only for an initial.
private extension StatsPeriod {
    var axisFormat: Date.FormatStyle {
        switch self {
        case .day: .dateTime.hour()
        case .week: .dateTime.weekday(.abbreviated)
        case .month: .dateTime.day()
        case .sixMonths: .dateTime.month(.abbreviated)
        case .year: .dateTime.month(.narrow)
        }
    }
}
