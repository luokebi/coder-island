import SwiftUI

struct SettingsView: View {
    @AppStorage("monitorClaudeCode") private var monitorClaudeCode = true
    @AppStorage("monitorCodex") private var monitorCodex = true
    @AppStorage("soundEnabled") private var soundEnabled = true
    @AppStorage("askHooksEnabled") private var askHooksEnabled = false
    @AppStorage("launchAtLogin") private var launchAtLogin = false

    var body: some View {
        Form {
            Section("Agent Monitoring") {
                Toggle("Claude Code", isOn: $monitorClaudeCode)
                Toggle("OpenAI Codex CLI", isOn: $monitorCodex)
            }

            Section("AskUserQuestion Hook") {
                Toggle("Answer questions from Coder Island", isOn: $askHooksEnabled)
                    .onChange(of: askHooksEnabled) { _, enabled in
                        if enabled {
                            HookInstaller.shared.install()
                        } else {
                            HookInstaller.shared.uninstall()
                        }
                    }
                Text("When enabled, Claude's questions will appear in Coder Island and you can answer directly. Requires restarting Claude Code sessions.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("General") {
                Toggle("Sound effects", isOn: $soundEnabled)
                Toggle("Launch at login", isOn: $launchAtLogin)
            }

            Section("About") {
                Text("Coder Island v0.1.0")
                    .foregroundColor(.secondary)
                Text("Monitor your AI coding agents from the notch.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380, height: 340)
    }
}
