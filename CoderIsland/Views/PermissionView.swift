import SwiftUI

/// Permission card shown inline inside a SessionCard, mirroring AskCardSwiftUI.
/// Displays Claude Code's 3 standard options: Allow once, Allow + don't ask again, Deny.
struct PermissionBannerView: View {
    let request: PermissionRequest
    let onAllow: () -> Void
    let onAllowAlways: () -> Void
    let onDeny: () -> Void

    private let orangeColor = Color.orange
    private let optBg = Color(red: 0.32, green: 0.22, blue: 0.08)

    private var titleLine: String {
        questionTitle(toolName: request.toolName)
    }

    private var bodyLine: String {
        // Primary content line — full URL / command / path, not truncated.
        primaryInput(toolName: request.toolName, input: request.toolInput)
            ?? request.description
    }

    private var subLine: String? {
        subText(toolName: request.toolName, input: request.toolInput)
    }

    private var allowAlwaysLabel: String {
        if let hint = request.allowSuggestion?.displayHint, !hint.isEmpty {
            return "Yes, and don't ask again for \(hint)"
        }
        return "Yes, and don't ask again for \(request.toolName)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header line with tool tag
            HStack(spacing: 6) {
                Circle()
                    .fill(orangeColor)
                    .frame(width: 7, height: 7)
                Text("Permission Request")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(orangeColor)
                Spacer()
                TagBadge(text: request.toolName)
            }

            // Claude Code-style body: tool title → primary content → description
            VStack(alignment: .leading, spacing: 4) {
                Text(titleLine)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                Text(bodyLine)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let sub = subLine {
                    Text(sub)
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // 3 numbered option rows (matches AskCardSwiftUI styling)
            VStack(spacing: 6) {
                PermissionOptionRow(index: 0, label: "Yes", tint: orangeColor, bg: optBg, action: onAllow)
                if request.allowSuggestion != nil {
                    PermissionOptionRow(index: 1, label: allowAlwaysLabel, tint: orangeColor, bg: optBg, action: onAllowAlways)
                }
                PermissionOptionRow(
                    index: request.allowSuggestion != nil ? 2 : 1,
                    label: "No, and tell Claude what to do differently",
                    tint: Color.red.opacity(0.75),
                    bg: Color(red: 0.32, green: 0.1, blue: 0.1),
                    action: onDeny
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func questionTitle(toolName: String) -> String {
        switch toolName {
        case "WebFetch": return "Do you want to allow Claude to fetch this content?"
        case "WebSearch": return "Do you want to allow Claude to run this web search?"
        case "Bash": return "Do you want to allow Claude to run this command?"
        case "Edit", "MultiEdit": return "Do you want to allow Claude to edit this file?"
        case "Write": return "Do you want to allow Claude to write this file?"
        case "Read": return "Do you want to allow Claude to read this file?"
        case "NotebookEdit": return "Do you want to allow Claude to edit this notebook?"
        case "Glob": return "Do you want to allow Claude to run this glob?"
        case "Grep": return "Do you want to allow Claude to run this grep?"
        case "Task": return "Do you want to allow Claude to launch this subagent?"
        default: return "Do you want to allow Claude to use \(toolName)?"
        }
    }

    private func primaryInput(toolName: String, input: [String: Any]) -> String? {
        switch toolName {
        case "WebFetch": return input["url"] as? String
        case "WebSearch": return input["query"] as? String
        case "Bash": return (input["command"] as? String).map { "$ \($0)" }
        case "Edit", "MultiEdit", "Write", "Read": return input["file_path"] as? String
        case "NotebookEdit": return input["notebook_path"] as? String
        case "Glob": return input["pattern"] as? String
        case "Grep":
            let pattern = input["pattern"] as? String ?? ""
            let path = input["path"] as? String ?? ""
            return path.isEmpty ? pattern : "\(pattern)  in  \(path)"
        case "Task": return input["description"] as? String
        default: return nil
        }
    }

    private func subText(toolName: String, input: [String: Any]) -> String? {
        switch toolName {
        case "WebFetch":
            if let url = input["url"] as? String,
               let host = URL(string: url)?.host {
                let prompt = (input["prompt"] as? String) ?? ""
                return prompt.isEmpty
                    ? "Claude wants to fetch content from \(host)"
                    : "Claude wants to fetch content from \(host) — \(prompt)"
            }
            return input["prompt"] as? String
        case "Bash":
            return input["description"] as? String
        case "Task":
            return input["prompt"] as? String
        default: return nil
        }
    }
}

private struct PermissionOptionRow: View {
    let index: Int
    let label: String
    let tint: Color
    let bg: Color
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(tint.opacity(0.3))
                        .frame(width: 26, height: 26)
                    Text("\(index + 1)")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(tint)
                }

                Text(label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isHovered ? bg.opacity(1) : bg.opacity(0.7))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Pure SwiftUI Ask Card (used by both hook and JSONL)

struct AskCardSwiftUI: View {
    let question: String
    let options: [(label: String, description: String)]
    let onSelect: (String) -> Void
    var showTerminalHint: Bool = false
    var userMessage: String? = nil

    private let tealColor = Color(red: 0.0, green: 0.75, blue: 0.75)
    private let optBg = Color(red: 0.1, green: 0.3, blue: 0.32)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Show user's message that triggered this ask
            if let msg = userMessage, !msg.isEmpty {
                Text(msg)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.gray)
                    .lineLimit(1)
                    .padding(.top, 4)
            }

            Text(question)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)

            VStack(spacing: 6) {
                ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                    SwiftUIOptionRow(index: index, label: option.label, desc: option.description, tealColor: tealColor, optBg: optBg) {
                        onSelect(option.label)
                    }
                }
            }

            if showTerminalHint {
                Text("Select in terminal — enable hooks for direct answers")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.gray.opacity(0.5))
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }
}

struct SwiftUIOptionRow: View {
    let index: Int
    let label: String
    let desc: String
    let tealColor: Color
    let optBg: Color
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        // Use SwiftUI `Button` (not `.onTapGesture`) so the first click
        // lands on the button even when the Notch window is not the key
        // window — AppKit's window-activation gesture swallows the first
        // click for tap-gesture recognizers, but Button has special
        // handling. Matches PermissionOptionRow's pattern.
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(tealColor.opacity(0.3))
                        .frame(width: 26, height: 26)
                    Text("\(index + 1)")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(tealColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                    if !desc.isEmpty {
                        Text(desc)
                            .font(.system(size: 11))
                            .foregroundColor(.gray)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isHovered ? optBg.opacity(1) : optBg.opacity(0.7))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Legacy AskBannerView (kept for compatibility)

struct AskBannerView: View {
    let request: AskRequest
    let onSubmit: (String) -> Void

    @State private var answer = ""

    private let tealColor = Color(red: 0.0, green: 0.75, blue: 0.75)
    private let optionBg = Color(red: 0.1, green: 0.3, blue: 0.32)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("🤖")
                    .font(.system(size: 12))
                Text("Claude's Question")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(tealColor)
            }

            Text(request.question)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)

            if !request.options.isEmpty {
                VStack(spacing: 8) {
                    ForEach(Array(request.options.enumerated()), id: \.offset) { index, option in
                        OptionRow(index: index, label: option.label, desc: option.description, tealColor: tealColor, optionBg: optionBg) {
                            onSubmit(option.label)
                        }
                    }
                }
            } else {
                HStack(spacing: 6) {
                    TextField("Your answer...", text: $answer)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08)))

                    Button(action: { onSubmit(answer) }) {
                        Text("Send")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 6).fill(tealColor.opacity(0.4)))
                    }
                    .buttonStyle(.plain)
                    .disabled(answer.isEmpty)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Clickable Option Row (NSView for reliable clicks in floating panels)

struct OptionRow: NSViewRepresentable {
    let index: Int
    let label: String
    let desc: String
    let tealColor: NSColor
    let optionBg: NSColor
    let action: () -> Void

    func makeNSView(context: Context) -> OptionButton {
        let btn = OptionButton(index: index, label: label, desc: desc, tealColor: tealColor, optionBg: optionBg)
        btn.onTap = action
        return btn
    }

    func updateNSView(_ nsView: OptionButton, context: Context) {}

    init(index: Int, label: String, desc: String = "", tealColor: Color, optionBg: Color, action: @escaping () -> Void) {
        self.index = index
        self.label = label
        self.desc = desc
        self.tealColor = NSColor(tealColor)
        self.optionBg = NSColor(optionBg)
        self.action = action
    }
}

class OptionButton: NSView {
    var onTap: (() -> Void)?
    private let index: Int
    private let label: String
    private let desc: String
    private let tealColor: NSColor
    private let optionBg: NSColor
    private var isHovered = false
    private var trackingArea: NSTrackingArea?

    init(index: Int, label: String, desc: String, tealColor: NSColor, optionBg: NSColor) {
        self.index = index
        self.label = label
        self.desc = desc
        self.tealColor = tealColor
        self.optionBg = optionBg
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = optionBg.withAlphaComponent(0.6).cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: desc.isEmpty ? 40 : 52)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        trackingArea = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(trackingArea!)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        layer?.backgroundColor = optionBg.withAlphaComponent(0.9).cgColor
    }
    override func mouseExited(with event: NSEvent) {
        isHovered = false
        layer?.backgroundColor = optionBg.withAlphaComponent(0.6).cgColor
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        if bounds.contains(loc) { onTap?() }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        // Left: number circle
        let numStr = "\(index + 1)"
        let circleSize: CGFloat = 26
        let circleY = (bounds.height - circleSize) / 2
        let circleRect = NSRect(x: 12, y: circleY, width: circleSize, height: circleSize)

        let circlePath = NSBezierPath(ovalIn: circleRect)
        tealColor.withAlphaComponent(0.3).setFill()
        circlePath.fill()

        let numAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .bold),
            .foregroundColor: tealColor
        ]
        let numSize = (numStr as NSString).size(withAttributes: numAttrs)
        (numStr as NSString).draw(at: NSPoint(
            x: circleRect.midX - numSize.width / 2,
            y: circleRect.midY - numSize.height / 2
        ), withAttributes: numAttrs)

        // Center: label + description
        let labelX: CGFloat = circleRect.maxX + 12
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white
        ]

        if desc.isEmpty {
            let labelSize = (label as NSString).size(withAttributes: labelAttrs)
            (label as NSString).draw(at: NSPoint(x: labelX, y: (bounds.height - labelSize.height) / 2), withAttributes: labelAttrs)
        } else {
            (label as NSString).draw(at: NSPoint(x: labelX, y: bounds.height - 20), withAttributes: labelAttrs)
            let descAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.gray
            ]
            (desc as NSString).draw(at: NSPoint(x: labelX, y: 8), withAttributes: descAttrs)
        }

    }
}

// MARK: - AskUserQuestion Card (from JSONL state)

struct AskQuestionCard: View {
    @ObservedObject var session: AgentSession

    private let tealColor = Color(red: 0.0, green: 0.75, blue: 0.75)
    private let optionBg = Color(red: 0.1, green: 0.3, blue: 0.32)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("🤖")
                    .font(.system(size: 12))
                Text("Claude's Question")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(tealColor)
            }

            if let question = session.askQuestion {
                Text(question)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
            }

            if let options = session.askOptions {
                VStack(spacing: 8) {
                    ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                        OptionRow(index: index, label: option.label, desc: option.description, tealColor: tealColor, optionBg: optionBg) {
                            session.jumpToTerminal()
                        }
                    }
                }
                Text("Select in terminal — enable hooks in Settings for direct answers")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.gray.opacity(0.5))
                    .padding(.top, 2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
