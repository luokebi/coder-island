import SwiftUI

struct PermissionBannerView: View {
    let request: PermissionRequest
    let onAllow: () -> Void
    let onDeny: () -> Void

    @State private var isAnimating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 8, height: 8)
                    .shadow(color: .orange.opacity(isAnimating ? 0.8 : 0.2), radius: isAnimating ? 4 : 1)

                Text("Permission Request")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.orange)

                Spacer()

                TagBadge(text: request.toolName)
            }

            // Description
            Text(request.description)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(.white)
                .lineLimit(3)

            // Buttons
            HStack(spacing: 8) {
                Spacer()

                Button(action: onDeny) {
                    Text("Deny")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.red.opacity(0.3))
                                .stroke(Color.red.opacity(0.5), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)

                Button(action: onAllow) {
                    Text("Allow")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.green.opacity(0.3))
                                .stroke(Color.green.opacity(0.5), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.orange.opacity(0.08))
                .stroke(Color.orange.opacity(0.2), lineWidth: 1)
        )
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                isAnimating = true
            }
        }
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
        HStack(spacing: 10) {
            // Number circle
            ZStack {
                Circle()
                    .fill(tealColor.opacity(0.3))
                    .frame(width: 26, height: 26)
                Text("\(index + 1)")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(tealColor)
            }

            // Label + description
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

            Spacer()

            // Shortcut
            Text("⌃\(index + 1)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.gray)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isHovered ? optBg.opacity(1) : optBg.opacity(0.7))
        )
        .onHover { isHovered = $0 }
        .onTapGesture { action() }
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

        // Right: ⌘N shortcut
        let shortcut = "⌃\(index + 1)"
        let shortcutAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.gray
        ]
        let shortcutSize = (shortcut as NSString).size(withAttributes: shortcutAttrs)
        (shortcut as NSString).draw(at: NSPoint(
            x: bounds.width - shortcutSize.width - 14,
            y: (bounds.height - shortcutSize.height) / 2
        ), withAttributes: shortcutAttrs)
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
