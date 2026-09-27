import SwiftUI

struct SettingsPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker("Refresh every", selection: $model.refreshInterval) {
                    Text("1 minute").tag(60.0)
                    Text("3 minutes").tag(180.0)
                    Text("5 minutes").tag(300.0)
                    Text("15 minutes").tag(900.0)
                }
                Picker("Menu bar shows", selection: $model.menuBarStyle) {
                    ForEach(MenuBarStyle.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Launch at login", isOn: $model.launchAtLogin)
            } header: {
                Text("General")
            }

            Section {
                Picker("Source", selection: Binding(get: { model.limitsSource ?? .off },
                                                    set: { model.limitsSource = $0; Task { await model.refresh(force: true) } })) {
                    ForEach(LimitsSource.allCases) { Text($0.label).tag($0) }
                }
                if model.limitsSource == .claudeCode || model.bridgeState != .notInstalled {
                    LabeledContent("Claude Code status line") {
                        HStack(spacing: 8) {
                            switch model.bridgeState {
                            case .installed:
                                Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.good)
                                Button("Disconnect") { model.uninstallBridge() }
                            case .needsRepair:
                                Label("Needs repair", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                                Button("Repair") { model.installBridge() }
                            case .notInstalled:
                                Text("Not connected").foregroundStyle(.secondary)
                                Button("Connect") { model.installBridge() }
                            }
                        }
                    }
                }
                if let error = model.bridgeError {
                    Text(error).font(.system(size: 11)).foregroundStyle(Theme.critical)
                }
            } header: {
                Text("Plan limits")
            } footer: {
                Group {
                    switch model.limitsSource ?? .off {
                    case .claudeCode:
                        Text("Claude Code passes your session and weekly limits to Headroom's helper through its status line (~/.claude/settings.json). Your previous status line, if any, keeps working and comes back if you disconnect. Nothing leaves your Mac.")
                    case .direct:
                        Text("Reads Claude Code's saved login with macOS's `security` tool (usually no keychain prompt) and calls Anthropic's undocumented usage endpoint. The token is only sent to api.anthropic.com and never stored. Anthropic's terms say third-party apps shouldn't use Claude Code's login, so use it at your own risk.")
                    case .off:
                        Text("Plan limits are off. Local Claude Code stats still work.")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }

            Section {
                if model.limitsSource == .direct {
                    LabeledContent("Plan limits") {
                        Button("Copy Last API Response") { model.copyLastResponse() }
                    }
                }
                LabeledContent("Local logs") {
                    HStack {
                        Button("Rescan") { Task { await model.rescanLocal() } }
                        Button("Show in Finder") {
                            NSWorkspace.shared.open(LogScanner.logsFolder)
                        }
                    }
                }
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("Local stats are read from Claude Code's logs and never leave your Mac.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")
                Button("Quit Headroom") { NSApp.terminate(nil) }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Theme.canvas)
    }
}
