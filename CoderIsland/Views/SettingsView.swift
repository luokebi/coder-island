import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct SettingsView: View {
    @AppStorage("monitorClaudeCode") private var monitorClaudeCode = true
    @AppStorage("monitorCodex") private var monitorCodex = true
    @AppStorage("soundEnabled") private var soundEnabled = true
    @AppStorage("soundPreset") private var soundPreset = SoundManager.Preset.mario.rawValue
    @AppStorage("soundPermissionEnabled") private var soundPermissionEnabled = true
    @AppStorage("soundAskEnabled") private var soundAskEnabled = true
    @AppStorage("soundTaskDoneEnabled") private var soundTaskDoneEnabled = true
    @AppStorage("soundAppStartedEnabled") private var soundAppStartedEnabled = true
    @AppStorage("askHooksEnabled") private var askHooksEnabled = false
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("smartSuppression") private var smartSuppression = true
    @AppStorage("showUsageLimits") private var showUsageLimits = true
    @AppStorage("hideInFullscreen") private var hideInFullscreen = false
    @AppStorage("preferredDisplayID") private var preferredDisplayID = 0
    @State private var displayChoices: [(id: Int, label: String)] = []

    @State private var isImportingSound = false
    @State private var importTarget: SoundManager.Event?
    @State private var permissionSoundName = ""
    @State private var askSoundName = ""
    @State private var doneSoundName = ""
    @State private var appStartedSoundName = ""
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
                            title: "Answer questions & permissions in Coder Island",
                            subtitle: "Install AskUserQuestion + permission hooks. Requires restarting Claude Code sessions."
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
                        rowDivider
                        soundEventRow(
                            title: "App started",
                            event: .appStarted,
                            currentCustomName: appStartedSoundName,
                            enabled: $soundAppStartedEnabled
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
                                .onChange(of: launchAtLogin) { _, enabled in
                                    let ok = LoginItemHelper.setEnabled(enabled)
                                    if !ok {
                                        // Roll back the UI toggle if the
                                        // system rejected the request
                                        // (e.g. running from DerivedData).
                                        DispatchQueue.main.async {
                                            launchAtLogin = !enabled
                                        }
                                    }
                                }
                        }
                        rowDivider
                        settingsRow(
                            title: "Display",
                            subtitle: "Which screen the notch lives on"
                        ) {
                            displayMenu
                        }
                    }

                    sectionTitle("Behaviour")
                    settingsCard {
                        settingsRow(
                            title: "Smart suppression",
                            subtitle: "Don't auto-expand when the agent's terminal is already in focus"
                        ) {
                            rightSwitch($smartSuppression)
                        }
                        rowDivider
                        settingsRow(
                            title: "Show usage limits",
                            subtitle: "Display subscription usage limits in the notch panel header"
                        ) {
                            rightSwitch($showUsageLimits)
                        }
                        rowDivider
                        settingsRow(
                            title: "Hide in fullscreen",
                            subtitle: "Hide Coder Island when any app is in fullscreen mode"
                        ) {
                            rightSwitch($hideInFullscreen)
                                .onChange(of: hideInFullscreen) { _, _ in
                                    NotificationCenter.default.post(
                                        name: .coderIslandReevaluateFullscreen,
                                        object: nil
                                    )
                                }
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
        // Pixel-art wordmark — no backdrop. Mostly blue with one orange
        // letter in CODER and one green letter in ISLAND, echoing the
        // Claude/Codex idle colors. Each letter has its own neon glow.
        let blue = Color(red: 0.30, green: 0.50, blue: 0.95)    // running (active)
        let orange = Color(red: 0.85, green: 0.52, blue: 0.35)   // Claude idle
        let green = Color(red: 0.25, green: 0.65, blue: 0.38)    // Codex idle

        return HStack(spacing: 24) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.none)
                .scaledToFit()
                .frame(width: 88, height: 88)

            VStack(alignment: .leading, spacing: 10) {
                PixelText(
                    text: "CODER",
                    colors: [orange],
                    cell: 3,
                    italic: true
                )
                PixelText(
                    text: "ISLAND",
                    colors: [blue, green, blue, green, blue, green],
                    cell: 3,
                    italic: true
                )
                Text("v\(appVersion)  //  SYSTEM ONLINE")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(1.5)
                    .foregroundColor(.white.opacity(0.55))
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
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
        HStack(alignment: .center, spacing: 16) {
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
        SoundManager.Preset(rawValue: soundPreset) ?? .mario
    }

    // Shared dropdown chrome — same rounded bordered pill used by every
    // settings menu so they line up visually and stay vertically centered.
    private func dropdownMenu<Items: View>(
        currentLabel: String,
        @ViewBuilder items: () -> Items
    ) -> some View {
        Menu {
            items()
        } label: {
            HStack(spacing: 8) {
                Text(currentLabel)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.95))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.55))
            }
            .padding(.horizontal, 12)
            .frame(minWidth: 140, minHeight: 30, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.09))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
    }

    private var displayMenu: some View {
        let currentLabel = displayChoices.first { $0.id == preferredDisplayID }?.label
            ?? "Automatic"
        return dropdownMenu(currentLabel: currentLabel) {
            ForEach(displayChoices, id: \.id) { choice in
                Button {
                    preferredDisplayID = choice.id
                    NotificationCenter.default.post(
                        name: .coderIslandReevaluateDisplay,
                        object: nil
                    )
                } label: {
                    HStack {
                        Text(choice.label)
                        if choice.id == preferredDisplayID {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        }
        .onAppear { displayChoices = NotchWindow.availableDisplayChoices() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didChangeScreenParametersNotification
        )) { _ in
            displayChoices = NotchWindow.availableDisplayChoices()
        }
    }

    private var presetMenu: some View {
        dropdownMenu(currentLabel: selectedPreset.displayName) {
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
        }
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
        appStartedSoundName = SoundManager.shared.customSoundName(for: .appStarted) ?? ""
    }
}

// MARK: - Pixel bitmap text

/// Renders a string using a hand-drawn 5x7 bitmap font. Only the
/// characters needed by the settings banner are defined; unknown
/// characters render as blank space.
struct PixelText: View {
    let text: String
    /// Per-letter colors. Cycles if shorter than the letter count.
    let colors: [Color]
    /// Size of a single pixel in points.
    var cell: CGFloat = 4
    /// Extra columns between letters.
    var letterSpacing: CGFloat = 0
    /// When true, each source row is nudged right to create an italic slant.
    var italic: Bool = false

    /// Single-color convenience init.
    init(text: String, color: Color, cell: CGFloat = 4, letterSpacing: CGFloat = 0, italic: Bool = false) {
        self.text = text
        self.colors = [color]
        self.cell = cell
        self.letterSpacing = letterSpacing
        self.italic = italic
    }

    init(text: String, colors: [Color], cell: CGFloat = 4, letterSpacing: CGFloat = 0, italic: Bool = false) {
        self.text = text
        self.colors = colors.isEmpty ? [.white] : colors
        self.cell = cell
        self.letterSpacing = letterSpacing
        self.italic = italic
    }

    // Classic 5x7 font. Each source pixel is rendered as a 2x2 block in
    // the Canvas so the original letter shapes are preserved but strokes
    // read as 2-pixel thick chunky blocks.
    private static let font: [Character: [String]] = [
        // Uppercase
        "C": [".####", "#....", "#....", "#....", "#....", "#....", ".####"],
        "O": [".###.", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."],
        "D": ["###..", "#..#.", "#...#", "#...#", "#...#", "#..#.", "###.."],
        "E": ["#####", "#....", "#....", "####.", "#....", "#....", "#####"],
        "R": ["####.", "#...#", "#...#", "####.", "#.#..", "#..#.", "#...#"],
        "I": ["#####", "..#..", "..#..", "..#..", "..#..", "..#..", "#####"],
        "S": [".####", "#....", "#....", ".###.", "....#", "....#", "####."],
        "L": ["#....", "#....", "#....", "#....", "#....", "#....", "#####"],
        "A": [".###.", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"],
        "N": ["#...#", "##..#", "##..#", "#.#.#", "#.##.", "#..##", "#...#"],
        // Lowercase — fit inside the same 5x7 cell
        "o": [".....", ".....", ".###.", "#...#", "#...#", "#...#", ".###."],
        "d": ["....#", "....#", ".####", "#...#", "#...#", "#...#", ".####"],
        "e": [".....", ".....", ".###.", "#...#", "#####", "#....", ".####"],
        "r": [".....", ".....", "#.##.", "##..#", "#....", "#....", "#...."],
        "s": [".....", ".....", ".####", "#....", ".###.", "....#", "####."],
        "l": ["##...", ".#...", ".#...", ".#...", ".#...", ".#...", ".###."],
        "a": [".....", ".....", ".###.", "....#", ".####", "#...#", ".####"],
        "n": [".....", ".....", "#.##.", "##..#", "#...#", "#...#", "#...#"],
        " ": [".....", ".....", ".....", ".....", ".....", ".....", "....."],
    ]

    var body: some View {
        // Keep case as-is so lowercase letters stay lowercase.
        let chars = Array(text)
        // Source glyph is 5x7. Each source pixel is rendered as a
        // single solid block of size `block = cell * 2` so strokes
        // read as chunky 2-thick pixel tiles (no internal sub-grid).
        let srcW = 5
        let srcH = 7
        let block = cell * 2
        let pix = max(block - 1.2, block * 0.82)
        let palette = colors
        // Italic skew: top row nudges right by ~1 block; bottom is fixed.
        let skewPerRow: CGFloat = italic ? block * 0.28 : 0
        let maxSkew = CGFloat(srcH - 1) * skewPerRow

        return HStack(spacing: letterSpacing * block) {
            ForEach(Array(chars.enumerated()), id: \.offset) { i, ch in
                let rows = PixelText.font[ch] ?? PixelText.font[" "]!
                let letterColor = palette[i % palette.count]
                Canvas { context, _ in
                    for (y, row) in rows.enumerated() {
                        let rowSkew = CGFloat(srcH - 1 - y) * skewPerRow
                        for (x, c) in row.enumerated() where c == "#" {
                            let rect = CGRect(
                                x: CGFloat(x) * block + rowSkew,
                                y: CGFloat(y) * block,
                                width: pix,
                                height: pix
                            )
                            context.fill(Path(rect), with: .color(letterColor))
                        }
                    }
                }
                .frame(
                    width: CGFloat(srcW) * block + maxSkew,
                    height: CGFloat(srcH) * block
                )
                .shadow(color: letterColor.opacity(0.95), radius: 2)
                .shadow(color: letterColor.opacity(0.6), radius: 5)
            }
        }
    }
}
