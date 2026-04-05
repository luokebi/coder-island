import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct SettingsView: View {
    @AppStorage("monitorClaudeCode") private var monitorClaudeCode = true
    @AppStorage("monitorCodex") private var monitorCodex = true
    @AppStorage("soundEnabled") private var soundEnabled = true
    @AppStorage("soundPreset") private var soundPreset = SoundManager.Preset.system.rawValue
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
                VStack(alignment: .leading, spacing: 24) {
                    appHeader

                    sectionTitle("Agent Monitoring")
                    settingsCard {
                        settingsRow(
                            title: "Claude Code",
                            subtitle: "Monitor Claude Code sessions"
                        ) {
                            rightSwitch($monitorClaudeCode)
                        }
                        rowDivider
                        settingsRow(
                            title: "OpenAI Codex CLI",
                            subtitle: "Monitor Codex sessions"
                        ) {
                            rightSwitch($monitorCodex)
                        }
                    }

                    sectionTitle("Interaction")
                    settingsCard {
                        settingsRow(
                            title: "Answer questions in Coder Island",
                            subtitle: "Use AskUserQuestion hook. Requires restarting Claude Code sessions."
                        ) {
                            rightSwitch($askHooksEnabled)
                                .onChange(of: askHooksEnabled) { _, enabled in
                                    if enabled {
                                        HookInstaller.shared.install()
                                    } else {
                                        HookInstaller.shared.uninstall()
                                    }
                                }
                        }
                    }

                    sectionTitle("Sound")
                    settingsCard {
                        settingsRow(
                            title: "Sound effects",
                            subtitle: "Play sounds for permission, question, and completion events."
                        ) {
                            rightSwitch($soundEnabled)
                        }
                        rowDivider
                        settingsRow(
                            title: "Sound preset",
                            subtitle: "Choose a built-in sound profile"
                        ) {
                            presetMenu
                                .disabled(!soundEnabled)
                        }
                        rowDivider
                        soundEventRow(
                            title: "Permission request",
                            event: .permission,
                            currentCustomName: permissionSoundName,
                            enabled: $soundPermissionEnabled
                        )
                        rowDivider
                        soundEventRow(
                            title: "Question",
                            event: .ask,
                            currentCustomName: askSoundName,
                            enabled: $soundAskEnabled
                        )
                        rowDivider
                        soundEventRow(
                            title: "Task completed",
                            event: .taskComplete,
                            currentCustomName: doneSoundName,
                            enabled: $soundTaskDoneEnabled
                        )
                    }

                    if !soundStatus.isEmpty {
                        Text(soundStatus)
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.65))
                            .padding(.horizontal, 4)
                    }

                    sectionTitle("System")
                    settingsCard {
                        settingsRow(
                            title: "Launch at login",
                            subtitle: "Start Coder Island automatically after login"
                        ) {
                            rightSwitch($launchAtLogin)
                        }
                    }

                }
                .padding(24)
            }
        }
        .frame(width: 760, height: 680)
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
                    soundStatus = "Applied custom override: \(url.lastPathComponent)"
                } catch {
                    soundStatus = "Failed to apply sound: \(error.localizedDescription)"
                }
            case .failure(let error):
                soundStatus = "File selection failed: \(error.localizedDescription)"
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 20, weight: .semibold))
            .foregroundColor(.white.opacity(0.95))
    }

    private var appHeader: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 74, height: 74)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.35), radius: 12, y: 6)

            Text(appDisplayName)
                .font(.system(size: 38, weight: .bold))
                .foregroundColor(.white.opacity(0.96))
                .tracking(-0.6)

            Text("Version \(appVersion)")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white.opacity(0.60))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    private var appDisplayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Coder Island"
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
        )
    }

    private func settingsRow<Accessory: View>(
        title: String,
        subtitle: String,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.white.opacity(0.95))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            accessory()
                .padding(.top, 1)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private func soundEventRow(
        title: String,
        event: SoundManager.Event,
        currentCustomName: String,
        enabled: Binding<Bool>
    ) -> some View {
        settingsRow(
            title: "\(title) sound",
            subtitle: currentSoundDisplayName(for: event, currentCustomName: currentCustomName)
        ) {
            VStack(alignment: .trailing, spacing: 8) {
                rightSwitch(enabled)
                HStack(spacing: 8) {
                    iconActionButton("play.fill", accessibilityLabel: "Preview") {
                        SoundManager.shared.playPreview(for: event)
                    }
                    .disabled(!soundEnabled || !enabled.wrappedValue)

                    actionButton("Upload") {
                        importTarget = event
                        isImportingSound = true
                    }
                    .disabled(!soundEnabled || !enabled.wrappedValue)

                    if !currentCustomName.isEmpty {
                        actionButton("Clear", foreground: .red.opacity(0.9)) {
                            SoundManager.shared.clearCustomSound(for: event)
                            refreshCustomSoundNames()
                            soundStatus = "Cleared custom sound for \(title.lowercased())."
                        }
                        .disabled(!soundEnabled || !enabled.wrappedValue)
                    }
                }
            }
            .opacity(soundEnabled ? 1 : 0.55)
        }
    }

    private func actionButton(
        _ title: String,
        foreground: Color = .white.opacity(0.95),
        action: @escaping () -> Void
    ) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(foreground)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.10))
            )
    }

    private func iconActionButton(
        _ systemName: String,
        accessibilityLabel: String,
        foreground: Color = .white.opacity(0.95),
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(foreground)
                .frame(width: 32, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.10))
                )
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(accessibilityLabel)
    }

    private var selectedPreset: SoundManager.Preset {
        SoundManager.Preset(rawValue: soundPreset) ?? .system
    }

    private var presetMenu: some View {
        Menu {
            ForEach(SoundManager.Preset.allCases) { preset in
                Button {
                    soundPreset = preset.rawValue
                } label: {
                    HStack {
                        Text(preset.displayName)
                        if preset == selectedPreset {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(selectedPreset.displayName)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.white.opacity(0.95))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.55))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(minWidth: 150, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.white.opacity(0.09))
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(Color.white.opacity(0.10), lineWidth: 1)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
    }

    private func rightSwitch(_ value: Binding<Bool>) -> some View {
        Toggle("", isOn: value)
            .labelsHidden()
            .toggleStyle(SwitchToggleStyle(tint: .blue))
            .controlSize(.regular)
    }

    private var rowDivider: some View {
        Divider()
            .overlay(Color.white.opacity(0.12))
            .padding(.horizontal, 18)
    }

    private func currentSoundDisplayName(for event: SoundManager.Event, currentCustomName: String) -> String {
        if currentCustomName.isEmpty {
            return SoundManager.shared.effectiveSoundLabel(for: event)
        }
        return "Custom override: \(currentCustomName)"
    }

    private func refreshCustomSoundNames() {
        permissionSoundName = SoundManager.shared.customSoundName(for: .permission) ?? ""
        askSoundName = SoundManager.shared.customSoundName(for: .ask) ?? ""
        doneSoundName = SoundManager.shared.customSoundName(for: .taskComplete) ?? ""
    }
}
