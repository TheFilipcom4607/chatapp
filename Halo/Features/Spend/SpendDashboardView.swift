import SwiftUI
import SwiftData
import Charts

struct SpendDashboardView: View {
    @Environment(AccountStore.self) private var account
    @Environment(ModelCatalog.self) private var catalog
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \UsageRecord.date) private var records: [UsageRecord]
    @Query private var conversations: [Conversation]
    @State private var range = 30

    private struct DayKind: Identifiable {
        var day: Date
        var kind: UsageKind
        var cost: Double
        var id: String { "\(day.timeIntervalSince1970)-\(kind.rawValue)" }
    }

    private var windowed: [UsageRecord] {
        let start = Calendar.current.date(byAdding: .day, value: -range + 1, to: Calendar.current.startOfDay(for: .now)) ?? .distantPast
        return records.filter { $0.date >= start }
    }

    private var byDay: [DayKind] {
        var dict: [String: DayKind] = [:]
        for r in windowed {
            let day = Calendar.current.startOfDay(for: r.date)
            let key = "\(day.timeIntervalSince1970)-\(r.kind.rawValue)"
            dict[key, default: DayKind(day: day, kind: r.kind, cost: 0)].cost += r.cost
        }
        return dict.values.sorted { $0.day < $1.day }
    }

    private var byModel: [(String, Double)] {
        var dict: [String: Double] = [:]
        for r in windowed { dict[r.modelID, default: 0] += r.cost }
        return dict.sorted { $0.value > $1.value }.prefix(6).map { ($0.key, $0.value) }
    }

    private var topChats: [(Conversation, Double)] {
        conversations.filter { $0.totalCost > 0 }.sorted { $0.totalCost > $1.totalCost }.prefix(5).map { ($0, $0.totalCost) }
    }

    private var total: Double { windowed.reduce(0) { $0 + $1.cost } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    balanceCard
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        stat("Today", account.keyInfo?.usageDaily)
                        stat("This week", account.keyInfo?.usageWeekly)
                        stat("This month", account.keyInfo?.usageMonthly)
                    }
                    chartCard
                    modelsCard
                    if !topChats.isEmpty { chatsCard }
                }
                .padding(16)
            }
            .background(Theme.background)
            .navigationTitle("Spending")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button { dismiss() } label: { Image(systemName: "xmark") } }
            }
            .refreshable { await account.refresh() }
            .task { await account.refresh() }
        }
    }

    private var balanceCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(account.balanceLabel.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
            Text(account.headline)
                .font(.system(size: 46, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(Theme.auroraGradient)
                .contentTransition(.numericText())
            if account.credits == nil {
                Text("Add a management key in Settings to see your total account balance.")
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
            if let updated = account.lastUpdated {
                Text("Updated \(updated.formatted(.relative(presentation: .named)))").font(.caption2).foregroundStyle(Theme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background { AuroraBackground(intensity: 0.7).clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous)) }
        .glassCard(cornerRadius: 28)
    }

    private func stat(_ title: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(Theme.textSecondary)
            Text(value.map { Money.format($0, compact: true) } ?? "–").font(.headline.monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .glassCard(cornerRadius: 18)
    }

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Spend in Halo").font(.headline)
                Spacer()
                Picker("Range", selection: $range) {
                    Text("7d").tag(7)
                    Text("30d").tag(30)
                    Text("90d").tag(90)
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
            }
            Text(Money.format(total)).font(.title2.weight(.bold).monospacedDigit())
            Chart(byDay) { item in
                BarMark(x: .value("Day", item.day, unit: .day), y: .value("Cost", item.cost))
                    .foregroundStyle(by: .value("Kind", item.kind.label))
                    .cornerRadius(4)
            }
            .chartForegroundStyleScale([
                UsageKind.chat.label: Theme.indigo,
                UsageKind.image.label: Theme.pink,
                UsageKind.video.label: Theme.violet,
                UsageKind.speech.label: Theme.teal,
                UsageKind.other.label: Color.gray,
            ])
            .chartYAxis { AxisMarks { v in AxisGridLine().foregroundStyle(Theme.hairline); AxisValueLabel { if let d = v.as(Double.self) { Text(Money.format(d, compact: true)) } } } }
            .frame(height: 200)
            .overlay {
                if byDay.isEmpty { Text("No spending yet").font(.subheadline).foregroundStyle(Theme.textTertiary) }
            }
        }
        .padding(16)
        .glassCard(cornerRadius: 24)
    }

    private var modelsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("By model").font(.headline)
            if byModel.isEmpty {
                Text("Nothing yet").font(.subheadline).foregroundStyle(Theme.textTertiary)
            } else {
                Chart(byModel, id: \.0) { item in
                    SectorMark(angle: .value("Cost", item.1), innerRadius: .ratio(0.62), angularInset: 2)
                        .foregroundStyle(by: .value("Model", catalog.displayName(item.0)))
                        .cornerRadius(4)
                }
                .frame(height: 180)
                ForEach(byModel, id: \.0) { item in
                    HStack {
                        Text(catalog.displayName(item.0)).font(.subheadline).lineLimit(1)
                        Spacer()
                        Text(Money.format(item.1)).font(.subheadline.monospacedDigit()).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
        .padding(16)
        .glassCard(cornerRadius: 24)
    }

    private var chatsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Priciest chats").font(.headline)
            ForEach(topChats, id: \.0.id) { item in
                Button {
                    dismiss()
                    app.open(item.0)
                } label: {
                    HStack {
                        Text(item.0.title).font(.subheadline).lineLimit(1).foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Text(Money.format(item.1)).font(.subheadline.monospacedDigit()).foregroundStyle(Theme.textSecondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .glassCard(cornerRadius: 24)
    }
}
