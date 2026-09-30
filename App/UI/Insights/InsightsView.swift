import SwiftUI

struct InsightsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: Binding<InsightsPage?>(get: { model.page }, set: { if let p = $0 { model.page = p } })) {
                Section {
                    ForEach([InsightsPage.overview, .activity, .projects]) { page in
                        Label(page.title, systemImage: page.symbol).tag(page)
                    }
                }
                Section {
                    Label(InsightsPage.settings.title, systemImage: InsightsPage.settings.symbol).tag(InsightsPage.settings)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
            .safeAreaInset(edge: .bottom) { SidebarStatus().padding(12) }
        } detail: {
            InsightsPageContent(page: model.page)
                .toolbar {
                    if model.page == .activity || model.page == .projects {
                        ToolbarItem(placement: .principal) {
                            Picker("Range", selection: $model.range) {
                                ForEach(LocalRange.allCases) { Text($0.label).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 240)
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            Task { await model.refresh(force: true) }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .disabled(model.isRefreshing)
                        .help("Refresh now (⌘R)")
                        .keyboardShortcut("r")
                    }
                }
        }
        .navigationTitle(model.page.title)
        .frame(minWidth: 960, minHeight: 660)
        .sheet(isPresented: Binding(get: { model.needsSetup }, set: { _ in })) {
            SetupView()
                .environment(model)
                .interactiveDismissDisabled()
        }
        .onAppear { NSApp.setActivationPolicy(.regular); NSApp.activate() }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
    }
}

/// The detail content for a page, without window chrome (also used for rendering previews).
struct InsightsPageContent: View {
    var page: InsightsPage

    var body: some View {
        switch page {
        case .overview: PageScroll { OverviewPage() }
        case .activity: PageScroll { ActivityPage() }
        case .projects: ProjectsPage()
        case .settings: SettingsPage()
        }
    }
}

/// The signed-in Claude account and refresh status, pinned to the bottom of the sidebar.
private struct SidebarStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let account = model.account {
                HStack(spacing: 10) {
                    AccountAvatar(account: account, size: 32)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(account.title)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let subtitle = account.subtitle {
                            Text(subtitle)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .help([account.name, account.email, account.organization].compactMap { $0 }.joined(separator: "\n"))
            }

            if let plan = model.planName { PlanBadge(plan: plan) }

            TimelineView(.periodic(from: .now, by: 5)) { context in
                let issue = model.limits.issue
                HStack(spacing: 4) {
                    Circle()
                        .fill(issue == nil ? Theme.good : issue!.isInformational ? Theme.neutral : Theme.warning)
                        .frame(width: 6, height: 6)
                    Text(model.isRefreshing ? "Refreshing…"
                         : issue == nil ? "Updated \(Fmt.ago(model.lastUpdated, now: context.date))"
                         : issue!.isInformational ? "Waiting for Claude Code" : "Limits need attention")
                        .lineLimit(1)
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            }
        }
    }
}

/// Initials on the brand gradient; a person icon when there are none.
struct AccountAvatar: View {
    var account: ClaudeAccount
    var size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [Theme.brandLight, Theme.brandDeep], startPoint: .topLeading, endPoint: .bottomTrailing))
            if !account.initials.isEmpty {
                Text(account.initials)
                    .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.42))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Layout building blocks

struct PageScroll<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) { content }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: 1180, alignment: .leading)
                .frame(maxWidth: .infinity)
        }
        .background(Theme.canvas)
    }
}

struct InsightCard<Accessory: View, Content: View>: View {
    var title: String?
    var subtitle: String?
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if title != nil || subtitle != nil {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        if let title { Text(title).font(.system(size: 13, weight: .semibold)) }
                        if let subtitle { Text(subtitle).font(.system(size: 11.5)).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    accessory
                }
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.cardStroke))
        .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
    }
}

extension InsightCard where Accessory == EmptyView {
    init(title: String? = nil, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, subtitle: subtitle, accessory: { EmptyView() }, content: content)
    }
}

struct PageHeader: View {
    var title: String
    var subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 26, weight: .bold))
            Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .padding(.bottom, 4)
    }
}

struct EmptyCardMessage: View {
    var symbol: String
    var text: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(.tertiary)
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }
}
