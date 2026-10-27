import BurnCore
import Charts
import SwiftUI

@MainActor final class UsageHistoryModel: ObservableObject {
  @Published var expanded = false
  @Published var days = 7
  @Published var hourly = true
  @Published var selectedModel = ""
  @Published var costChart = false
  @Published var ledger = ReviewLedger()
  @Published var error: String?
  let root: URL
  init(root: URL = Store.defaultRoot) { self.root = root }
  func reload() {
    do { ledger = try ReviewLedger.load(store: Store(root: root)); error = nil }
    catch { self.error = error.localizedDescription }
  }
  var report: UsageReport { .make(ledger, days: days, hourly: hourly, model: selectedModel.isEmpty ? nil : selectedModel) }
}

struct UsageHistoryView: View {
  @StateObject var usage: UsageHistoryModel
  @State private var selectedDate: Date?
  private let orange = Color(red: 1, green: 0.34, blue: 0.12)
  init(root: URL = Store.defaultRoot) { _usage = StateObject(wrappedValue: UsageHistoryModel(root: root)) }
  init(model: UsageHistoryModel) { _usage = StateObject(wrappedValue: model) }
  private func tokens(_ value: Int) -> String { value.formatted(.number.notation(.compactName)) }
  private func dollars(_ value: Double) -> String { value.formatted(.currency(code: "USD").precision(.fractionLength(value < 0.01 && value > 0 ? 4 : (value < 1 && value > 0 ? 3 : 2)))) }
  var body: some View {
    DisclosureGroup(isExpanded: $usage.expanded) {
      VStack(alignment: .leading, spacing: 16) {
        HStack {
          Picker("Range", selection: $usage.days) {
            ForEach(1...30, id: \.self) { Text($0 == 1 ? "1 day" : "\($0) days").tag($0) }
          }.accessibilityIdentifier("usage-range")
          Picker("Buckets", selection: $usage.hourly) {
            Text("Hourly").tag(true); Text("Daily").tag(false)
          }.pickerStyle(.segmented).labelsHidden().accessibilityIdentifier("usage-buckets")
        }
        Picker("Model", selection: $usage.selectedModel) {
          Text("All models").tag("")
          ForEach(usage.report.models) { Text($0.model).tag($0.model) }
        }.accessibilityIdentifier("usage-model")
        let report = usage.report
        HStack(alignment: .firstTextBaseline) {
          VStack(alignment: .leading, spacing: 4) {
            Text(dollars(report.total.estimatedUSD)).font(.system(size: 27, weight: .semibold, design: .rounded)).foregroundStyle(orange)
            Text("Estimated API cost").font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          VStack(alignment: .trailing, spacing: 4) {
            Text("\(report.total.reviews) reviews").font(.headline)
            Text("\(tokens(report.total.input + report.total.output)) total tokens").font(.caption).foregroundStyle(.secondary)
          }
        }
        tokenRow(report.total)
        Picker("Chart", selection: $usage.costChart) {
          Text("Tokens").tag(false); Text("Estimated cost").tag(true)
        }.pickerStyle(.segmented).accessibilityIdentifier("usage-chart-metric")
        Chart {
          ForEach(report.buckets) { bucket in
            if usage.costChart {
              BarMark(x: .value("Time", bucket.date, unit: usage.hourly ? .hour : .day), y: .value("USD", bucket.totals.estimatedUSD)).foregroundStyle(orange)
            } else {
              BarMark(x: .value("Time", bucket.date, unit: usage.hourly ? .hour : .day), y: .value("Tokens", bucket.totals.uncached)).foregroundStyle(by: .value("Type", "Uncached"))
              BarMark(x: .value("Time", bucket.date, unit: usage.hourly ? .hour : .day), y: .value("Tokens", bucket.totals.cached)).foregroundStyle(by: .value("Type", "Cached"))
              BarMark(x: .value("Time", bucket.date, unit: usage.hourly ? .hour : .day), y: .value("Tokens", bucket.totals.cacheWrite)).foregroundStyle(by: .value("Type", "Cache writes"))
              BarMark(x: .value("Time", bucket.date, unit: usage.hourly ? .hour : .day), y: .value("Tokens", bucket.totals.output)).foregroundStyle(by: .value("Type", "Output"))
            }
          }
          if let selectedDate {
            RuleMark(x: .value("Selected", selectedDate)).foregroundStyle(.secondary.opacity(0.5))
          }
        }
        .chartForegroundStyleScale(["Uncached": orange, "Cached": Color.teal.opacity(0.7), "Cache writes": Color.yellow.opacity(0.75), "Output": Color.gray])
        .chartLegend(position: .bottom, alignment: .leading, spacing: 8)
        .chartXSelection(value: $selectedDate)
        .chartXAxis {
          AxisMarks(values: .automatic(desiredCount: 4)) { value in
            AxisGridLine()
            AxisValueLabel {
              if let date = value.as(Date.self) {
                Text(date.formatted(usage.hourly && usage.days == 1 ? .dateTime.hour() : .dateTime.month(.abbreviated).day()))
              }
            }
          }
        }
        .chartYAxis { AxisMarks(position: .leading) }
        .frame(height: 190).accessibilityIdentifier("usage-chart")
        if let selectedDate, let bucket = report.buckets.min(by: { abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate)) }) {
          Text("\(bucket.date.formatted(date: .abbreviated, time: usage.hourly ? .shortened : .omitted)) · \(tokens(bucket.totals.input)) in · \(tokens(bucket.totals.output)) out · \(dollars(bucket.totals.estimatedUSD))")
            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        if report.total.reviews == 0 {
          Text("No reviews in this range. Passive observation uses no model tokens.").font(.callout).foregroundStyle(.secondary)
        }
        if report.total.unknown + report.total.unpriced > 0 {
          Text("\(report.total.unknown) review(s) have unavailable usage. \(report.total.unpriced) model total(s) are unpriced and excluded from cost.")
            .font(.caption).foregroundStyle(.secondary)
        }
        if !report.models.isEmpty {
          Divider()
          Text("By model").font(.subheadline.weight(.semibold))
          ForEach(report.models.filter { usage.selectedModel.isEmpty || $0.model == usage.selectedModel }) { row in
            VStack(alignment: .leading, spacing: 8) {
              HStack(alignment: .firstTextBaseline) {
                Text(row.model).font(.caption.weight(.semibold)).textSelection(.enabled)
                Spacer()
                Text(row.totals.unpriced > 0 ? "Unpriced" : dollars(row.totals.estimatedUSD)).font(.caption.monospacedDigit()).foregroundStyle(orange)
              }
              tokenRow(row.totals)
            }.padding(10).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
          }
        }
        Text("Input \(report.total.input.formatted()) = uncached \(report.total.uncached.formatted()) + cached \(report.total.cached.formatted()) + cache writes \(report.total.cacheWrite.formatted()). Output \(report.total.output.formatted()) includes reasoning where reported.")
          .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
        Text("BurnZombies reviews only. API-equivalent USD estimates use recorded models and rates saved with each review. Subscription credits, hidden approval overhead and unavailable usage are not inferred. Rate card: \(ModelPricing.date).")
          .font(.caption2).foregroundStyle(.secondary)
        HStack {
          Link("OpenAI rates", destination: URL(string: ModelPricing.openAI)!)
          Link("Claude rates", destination: URL(string: ModelPricing.anthropic)!)
          Spacer()
          Button("Refresh") { usage.reload() }.accessibilityIdentifier("usage-refresh")
        }.font(.caption)
        if let error = usage.error { Text(error).font(.caption).foregroundStyle(.orange) }
      }.padding(.top, 14)
    } label: {
      Label("Usage & estimated cost", systemImage: "chart.bar.xaxis").font(.callout.weight(.medium))
    }.padding(14)
      .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
      .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
      .onChange(of: usage.expanded) { _, expanded in if expanded { usage.reload() } }
      .onChange(of: usage.days) { _, _ in selectedDate = nil }
      .onChange(of: usage.hourly) { _, _ in selectedDate = nil }
      .onChange(of: usage.selectedModel) { _, _ in selectedDate = nil }
      .accessibilityIdentifier("usage-disclosure")
  }
  private func tokenRow(_ totals: UsageTotals) -> some View {
    HStack(spacing: 6) {
      tokenCell("Uncached in", totals.uncached)
      tokenCell("Cached in", totals.cached)
      tokenCell("Cache writes", totals.cacheWrite)
      tokenCell("Output", totals.output)
    }
  }
  private func tokenCell(_ label: String, _ value: Int) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(tokens(value)).font(.system(.callout, design: .monospaced).weight(.medium))
      Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
    }.frame(maxWidth: .infinity, alignment: .leading).help(value.formatted())
  }
}
