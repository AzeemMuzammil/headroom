import AppKit
import SwiftUI

@main
struct HeadroomApp: App {
    @State private var model: AppModel

    init() {
        let args = CommandLine.arguments
        // Debug helpers: `--dump-local` prints local totals; `--render-preview <dir>` renders the UI with sample data.
        if args.contains("--dump-local") { Self.dumpLocalStats() }
        if let i = args.firstIndex(of: "--render-preview"), i + 1 < args.count {
            MainActor.assumeIsolated { PreviewRenderer.run(to: args[i + 1]) }
        }
        _model = State(initialValue: args.contains("--demo") ? PreviewData.model() : AppModel())
    }

    var body: some Scene {
        MenuBarExtra {
            MenuPanel()
                .environment(model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("Headroom", id: "insights") {
            InsightsView()
                .environment(model)
        }
        .defaultSize(width: 1120, height: 780)
        // Open straight into setup on first launch; otherwise stay in the menu bar.
        .defaultLaunchBehavior(model.needsSetup ? .presented : .suppressed)
        .windowToolbarStyle(.unified(showsTitle: false))
    }

    private static func dumpLocalStats() -> Never {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let start = Date()
            let stats = await LogScanner().scan()
            for range in LocalRange.allCases {
                if let s = stats.summary(range) {
                    print("\(range.label): \(s.messages) replies, \(s.tokens.total) tokens, $\(String(format: "%.2f", s.cost)), cache saved $\(String(format: "%.2f", s.cacheSavings)), \(s.projects.count) projects")
                }
            }
            print("files: \(stats.filesScanned), active days: \(stats.days.filter { $0.messages > 0 }.count)")
            print(String(format: "scanned in %.2fs", Date().timeIntervalSince(start)))
            done.signal()
        }
        done.wait()
        exit(0)
    }
}

// MARK: - Menu bar label

struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        let session = model.limits.session
        let style = model.menuBarStyle
        HStack(spacing: 4) {
            if style != .percent || session == nil {
                Image(nsImage: MenuBarIcon.image(for: session))
            }
            if style != .ring, let session {
                Text(Fmt.percent(session.utilization))
                    .monospacedDigit()
            }
        }
    }
}

enum MenuBarIcon {
    /// A small ring in the brand (or status) colour; the spark mark when there's no data yet.
    static func image(for session: LimitWindow?) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        guard let session else {
            // No data yet: the app's ring mark as a template image (adapts to the menu bar).
            let image = NSImage(size: size, flipped: false) { rect in
                let r = rect.insetBy(dx: 2, dy: 2)
                let track = NSBezierPath(ovalIn: r)
                track.lineWidth = 2.2
                NSColor.black.withAlphaComponent(0.35).setStroke()
                track.stroke()
                let arc = NSBezierPath()
                arc.appendArc(withCenter: CGPoint(x: r.midX, y: r.midY), radius: r.width / 2, startAngle: 90, endAngle: 90 - 260, clockwise: true)
                arc.lineWidth = 2.2
                arc.lineCapStyle = .round
                NSColor.black.setStroke()
                arc.stroke()
                return true
            }
            image.isTemplate = true
            return image
        }

        let color = LimitStatus.menuBarColor(for: session)
        let image = NSImage(size: size, flipped: false) { rect in
            let lineWidth: CGFloat = 2.6
            let r = rect.insetBy(dx: lineWidth / 2 + 0.5, dy: lineWidth / 2 + 0.5)
            let track = NSBezierPath(ovalIn: r)
            track.lineWidth = lineWidth
            NSColor.gray.withAlphaComponent(0.45).setStroke()
            track.stroke()

            let f = min(max(session.fraction, 0), 1)
            if f > 0 {
                let arc = NSBezierPath()
                arc.appendArc(withCenter: CGPoint(x: r.midX, y: r.midY), radius: r.width / 2,
                              startAngle: 90, endAngle: 90 - 360 * f, clockwise: true)
                arc.lineWidth = lineWidth
                arc.lineCapStyle = .round
                color.setStroke()
                arc.stroke()
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}
