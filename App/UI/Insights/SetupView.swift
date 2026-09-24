import SwiftUI

/// First-launch choice of where plan limits come from.
struct SetupView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                AppMark(size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Welcome to Headroom").font(.system(size: 22, weight: .bold))
                    Text("Your Claude plan limits and Claude Code usage, in the menu bar.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }

            Text("How should Headroom get your plan limits?")
                .font(.system(size: 14, weight: .semibold))

            HStack(alignment: .top, spacing: 14) {
                OptionCard(
                    symbol: "terminal",
                    title: "Through Claude Code",
                    badge: "Recommended",
                    points: [
                        "Claude Code passes your session and weekly limits to Headroom through its status line.",
                        "Headroom never touches your login and sends nothing over the network.",
                        "Limits update while you use Claude Code.",
                        "Adds a status line entry to ~/.claude/settings.json. An existing status line keeps working, and a backup is saved.",
                    ],
                    warning: nil,
                    action: "Connect to Claude Code"
                ) {
                    // Only leave setup once Claude Code is actually connected.
                    if model.installBridge() { model.limitsSource = .claudeCode }
                }

                OptionCard(
                    symbol: "key",
                    title: "Direct",
                    badge: nil,
                    points: [
                        "Reads Claude Code's saved login from your keychain and asks Anthropic for your limits.",
                        "Adds model-specific limits and the weekly breakdown, and updates even when Claude Code is closed.",
                        "macOS asks once for keychain access.",
                    ],
                    warning: "Anthropic's terms say third-party apps shouldn't use Claude Code's login. The endpoint is undocumented and may change. Use at your own risk.",
                    action: "Use Direct Mode"
                ) {
                    model.limitsSource = .direct
                    Task { await model.refresh(force: true) }
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            if let error = model.bridgeError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.critical)
            }

            HStack {
                Button("Skip — show local Claude Code stats only") {
                    model.limitsSource = .off
                    Task { await model.refresh(force: true) }
                }
                .buttonStyle(.link)
                Spacer()
                Text("You can change this anytime in Settings.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(28)
        .frame(width: 720)
    }
}

private struct OptionCard: View {
    var symbol: String
    var title: String
    var badge: String?
    var points: [String]
    var warning: String?
    var action: String
    var perform: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.brand)
                Text(title).font(.system(size: 14, weight: .semibold))
                if let badge {
                    Text(badge.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.4)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Theme.brand.opacity(0.15)))
                        .foregroundStyle(Theme.brand)
                }
            }
            VStack(alignment: .leading, spacing: 7) {
                ForEach(points, id: \.self) { point in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                        Text(point).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let warning {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                    Text(warning).font(.system(size: 11.5)).fixedSize(horizontal: false, vertical: true)
                }
                .padding(9)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.warning.opacity(0.12)))
            }
            Spacer(minLength: 0)
            Button(action: perform) {
                Text(action).frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(badge != nil ? Theme.brand : .gray)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(badge != nil ? Theme.brand.opacity(0.5) : Theme.cardStroke))
    }
}
