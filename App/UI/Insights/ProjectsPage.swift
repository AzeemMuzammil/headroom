import Charts
import SwiftUI

struct ProjectsPage: View {
    @Environment(AppModel.self) private var model
    @State private var sortOrder = [KeyPathComparator(\ProjectRow.tokens, order: .reverse)]
    @State private var selection: ProjectRow.ID?

    struct ProjectRow: Identifiable {
        var name: String
        var tokens: Int
        var cost: Double
        var replies: Int
        var share: Double
        var lastActive: Date
        var id: String { name }
    }

    var body: some View {
        let summary = model.summary
        let total = max(summary?.tokens.total ?? 0, 1)
        let rows = (summary?.projects ?? []).map {
            ProjectRow(name: $0.name, tokens: $0.usage.tokens, cost: $0.usage.cost, replies: $0.usage.messages,
                       share: Double($0.usage.tokens) / Double(total), lastActive: $0.usage.lastActive ?? .distantPast)
        }
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(title: "Projects",
                       subtitle: "\(rows.count) projects with Claude Code activity · \(model.range.label.lowercased())")
            if rows.isEmpty {
                InsightCard { EmptyCardMessage(symbol: "folder", text: "No Claude Code activity in this period.") }
            } else {
                InsightCard(title: "Top projects", subtitle: "By tokens") {
                    TopProjectsChart(rows: Array(rows.prefix(5)))
                }
                .fixedSize(horizontal: false, vertical: true)

                Table(rows.sorted(using: sortOrder), selection: $selection, sortOrder: $sortOrder) {
                    TableColumn("Project", value: \.name) { row in
                        Label(row.name, systemImage: "folder.fill")
                            .labelStyle(ProjectLabelStyle())
                    }
                    .width(min: 120, ideal: 180)
                    TableColumn("Tokens", value: \.tokens) { Text(Fmt.tokens($0.tokens)).monospacedDigit() }
                        .width(min: 56, ideal: 68)
                    TableColumn("API value", value: \.cost) { Text(Fmt.cost($0.cost)).monospacedDigit() }
                        .width(min: 56, ideal: 68)
                    TableColumn("Replies", value: \.replies) { Text($0.replies.formatted()).monospacedDigit() }
                        .width(min: 48, ideal: 56)
                    TableColumn("Share", value: \.share) { row in
                        HStack(spacing: 8) {
                            LimitBar(fraction: row.share, tint: Theme.brand, height: 5)
                            Text("\(Int((row.share * 100).rounded()))%")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 30, alignment: .trailing)
                        }
                    }
                    .width(min: 80, ideal: 110)
                    TableColumn("Last active", value: \.lastActive) { row in
                        Text(row.lastActive == .distantPast ? "—" : Fmt.relativeDay(row.lastActive))
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 76, ideal: 86)
                }
                .tableStyle(.inset)
                .alternatingRowBackgrounds(.disabled)
                .scrollContentBackground(.hidden)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.cardStroke))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .frame(minHeight: 120, maxHeight: .infinity)
                .layoutPriority(1)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.canvas)
    }
}

private struct TopProjectsChart: View {
    var rows: [ProjectsPage.ProjectRow]

    var body: some View {
        let top = Double(max(rows.first?.tokens ?? 1, 1))
        VStack(spacing: 11) {
            ForEach(rows) { row in
                HStack(spacing: 14) {
                    Text(row.name)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(width: 190, alignment: .leading)
                    LimitBar(fraction: Double(row.tokens) / top, tint: Theme.brand, height: 9)
                    Text("\(Fmt.tokens(row.tokens)) · \(Fmt.cost(row.cost))")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 120, alignment: .trailing)
                }
            }
        }
    }
}

private struct ProjectLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 7) {
            configuration.icon.foregroundStyle(Theme.brand.opacity(0.85)).font(.system(size: 11))
            configuration.title.lineLimit(1).truncationMode(.middle)
        }
    }
}
