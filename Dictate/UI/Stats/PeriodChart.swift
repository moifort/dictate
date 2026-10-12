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
                AxisValueLabel(format: series.period.axisFormat, centered: series.period.axisCentered)
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

    /// Where a date goes under the columns: one per column for a week or a
    /// year, every six hours of the day, every week of the month, and the
    /// first of each month over six months.
    private var axisDates: [Date] {
        let starts = series.buckets.map(\.date)
        switch series.period {
        case .day: return stride(from: 0, to: starts.count, by: 6).map { starts[$0] }
        case .week, .year: return starts
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

/// How the dates read under each period.
private extension StatsPeriod {
    var axisFormat: Date.FormatStyle {
        switch self {
        case .day: .dateTime.hour()
        case .week: .dateTime.weekday(.narrow)
        case .month: .dateTime.day()
        case .sixMonths: .dateTime.month(.abbreviated)
        case .year: .dateTime.month(.narrow)
        }
    }

    /// Under the column when one label names one column.
    var axisCentered: Bool {
        switch self {
        case .week, .year: true
        case .day, .month, .sixMonths: false
        }
    }
}
