import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @AppStorage("monitorClaudeCode") private var monitorClaudeCode = true
    @AppStorage("monitorCodex") private var monitorCodex = true
    @AppStorage("soundEnabled") private var soundEnabled = true
    @AppStorage("soundPermissionEnabled") private var soundPermissionEnabled = true
    @AppStorage("soundAskEnabled") private var soundAskEnabled = true
    @AppStorage("soundTaskDoneEnabled") private var soundTaskDoneEnabled = true
    @AppStorage("askHooksEnabled") private var askHooksEnabled = false
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @State private var isImportingSound = false
    @State private var importTarget: SoundManager.Event?
    @State private var permissionSoundName = ""
    @State private var askSoundName = ""
    @State private var doneSoundName = ""
    @State private var soundStatus = ""

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 14) {
                    sectionCard("Agent Monitoring") {
                        toggleRow("Claude Code", isOn: $monitorClaudeCode)
                        dividerRow
                        toggleRow("OpenAI Codex CLI", isOn: $monitorCodex)
                    }

                    sectionCard("AskUserQuestion Hook") {
                        toggleRow("Answer questions from Coder Island", isOn: $askHooksEnabled)
                            .onChange(of: askHooksEnabled) { _, enabled in
                                if enabled {
                                    HookInstaller.shared.install()
                                } else {
                                    HookInstaller.shared.uninstall()
                                }
                            }
                        Text("When enabled, Claude's questions will appear in Coder Island and you can answer directly. Requires restarting Claude Code sessions.")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.65))
                            .padding(.top, 2)
                    }

                    sectionCard("General") {
                        toggleRow("Sound effects", isOn: $soundEnabled)
                        dividerRow
                        customSoundRow(
                            title: "Permission request",
                            event: .permission,
                            currentName: permissionSoundName,
                            enabled: $soundPermissionEnabled
                        )
                        dividerRow
                        customSoundRow(
                            title: "Question",
                            event: .ask,
                            currentName: askSoundName,
                            enabled: $soundAskEnabled
                        )
                        dividerRow
                        customSoundRow(
                            title: "Task completed",
                            event: .taskComplete,
                            currentName: doneSoundName,
                            enabled: $soundTaskDoneEnabled
                        )
                        dividerRow
                        toggleRow("Launch at login", isOn: $launchAtLogin)
                        if !soundStatus.isEmpty {
                            Text(soundStatus)
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.65))
                                .padding(.top, 2)
                        }
                    }

                    sectionCard("About") {
                        Text("Coder Island v0.1.0")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white.opacity(0.85))
                        Text("Monitor your AI coding agents from the notch.")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.65))
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 500, height: 600)
        .preferredColorScheme(.dark)
        .onAppear {
            refreshCustomSoundNames()
        }
        .fileImporter(
            isPresented: $isImportingSound,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: false
        ) { result in
            guard let event = importTarget else { return }
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                do {
                    try SoundManager.shared.setCustomSound(for: event, from: url)
                    refreshCustomSoundNames()
                    soundStatus = "Applied custom sound: \(url.lastPathComponent)"
                } catch {
                    soundStatus = "Failed to apply sound: \(error.localizedDescription)"
                }
            case .failure(let error):
                soundStatus = "File selection failed: \(error.localizedDescription)"
            }
        }
    }

    @ViewBuilder
    private func sectionCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))

            VStack(alignment: .leading, spacing: 0) {
                content()
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                )
        )
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.95))
        }
        .toggleStyle(SwitchToggleStyle(tint: .blue))
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func customSoundRow(
        title: String,
        event: SoundManager.Event,
        currentName: String,
        enabled: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(title) sound")
                    .foregroundColor(.white.opacity(0.95))
                Spacer()
                Toggle("", isOn: enabled)
                    .labelsHidden()
            }

            HStack {
                Text(currentName.isEmpty ? "System default" : currentName)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.65))
                    .lineLimit(1)
                Spacer()
                Button("Preview") {
                    SoundManager.shared.playPreview(for: event)
                }
                .buttonStyle(.bordered)
                .tint(.white.opacity(0.14))
                .foregroundColor(.white)
                .disabled(!soundEnabled || !enabled.wrappedValue)

                Button("Upload") {
                    importTarget = event
                    isImportingSound = true
                }
                .buttonStyle(.bordered)
                .tint(.white.opacity(0.14))
                .foregroundColor(.white)
                .disabled(!soundEnabled || !enabled.wrappedValue)

                if !currentName.isEmpty {
                    Button("Clear") {
                        SoundManager.shared.clearCustomSound(for: event)
                        refreshCustomSoundNames()
                        soundStatus = "Cleared custom sound for \(title.lowercased())."
                    }
                    .buttonStyle(.bordered)
                    .tint(.red.opacity(0.28))
                    .foregroundColor(.red.opacity(0.9))
                    .disabled(!soundEnabled || !enabled.wrappedValue)
                }
            }
        }
        .padding(.vertical, 8)
        .disabled(!soundEnabled)
        .opacity(soundEnabled ? 1 : 0.6)
    }

    private var dividerRow: some View {
        Divider()
            .overlay(Color.white.opacity(0.10))
            .padding(.vertical, 2)
    }

    private func refreshCustomSoundNames() {
        permissionSoundName = SoundManager.shared.customSoundName(for: .permission) ?? ""
        askSoundName = SoundManager.shared.customSoundName(for: .ask) ?? ""
        doneSoundName = SoundManager.shared.customSoundName(for: .taskComplete) ?? ""
    }
}
