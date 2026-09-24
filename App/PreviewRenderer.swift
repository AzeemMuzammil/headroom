import AppKit
import SwiftUI

/// `Headroom --render-preview <dir>` renders the menu and every Insights page with sample data
/// to PNGs in light and dark, for design review without clicking through the app.
enum PreviewRenderer {
    @MainActor
    static func run(to dir: String) -> Never {
        _ = NSApplication.shared
        // `--live` renders your real saved snapshot instead of sample data. It includes your project
        // names — do not share these renders.
        let model = CommandLine.arguments.contains("--live")
            ? AppModel(preview: Store.load(UsageSnapshot.self, "snapshot.json") ?? UsageSnapshot(),
                       history: Store.load([LimitSample].self, "limit-history.json") ?? [])
            : PreviewData.model()
        let out = URL(fileURLWithPath: dir)
        for (name, appearance) in [("light", NSAppearance(named: .aqua)!), ("dark", NSAppearance(named: .darkAqua)!)] {
            NSApp.appearance = appearance
            render(MenuPanel().environment(model), size: nil, appearance: appearance,
                   to: out.appendingPathComponent("menu-\(name).png"))
            render(SetupView().environment(model), size: nil, appearance: appearance,
                   to: out.appendingPathComponent("setup-\(name).png"))
            for page in InsightsPage.allCases {
                model.page = page
                render(InsightsView().environment(model), size: NSSize(width: 960, height: 660),
                       appearance: appearance, to: out.appendingPathComponent("window-\(page.rawValue)-\(name).png"))
            }
            for page in InsightsPage.allCases {
                model.page = page
                render(pageBody(page).environment(model), size: page == .overview || page == .activity ? nil : NSSize(width: 1000, height: 760),
                       appearance: appearance, to: out.appendingPathComponent("\(page.rawValue)-\(name).png"))
            }
        }
        exit(0)
    }

    /// Scrolling pages are rendered unscrolled at their natural height, so images are cropped to content.
    @MainActor @ViewBuilder
    private static func pageBody(_ page: InsightsPage) -> some View {
        switch page {
        case .overview: VStack(alignment: .leading, spacing: 18) { OverviewPage() }.padding(28).frame(width: 1000)
        case .activity: VStack(alignment: .leading, spacing: 18) { ActivityPage() }.padding(28).frame(width: 1000)
        default: InsightsPageContent(page: page)
        }
    }

    /// Renders through a real (offscreen) window so AppKit-backed views like Table and Form draw too.
    @MainActor
    private static func render<V: View>(_ view: V, size: NSSize?, appearance: NSAppearance, to url: URL) {
        let host = NSHostingView(rootView: view.background(Theme.canvas))
        let fitting = size ?? host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: fitting), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: fitting)
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
