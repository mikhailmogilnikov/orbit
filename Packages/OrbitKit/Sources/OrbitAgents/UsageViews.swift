import OrbitUI
import SwiftUI

/// The composer's context ring (its percentage once it's worth watching);
/// click for context, plan limits and what the chat cost.
struct UsageButton: View {
    let session: AgentSession
    @State private var isPresented = false
    @State private var isHovering = false

    private var usage: SessionUsage { session.usage }

    var body: some View {
        Button { isPresented.toggle() } label: {
            HStack(spacing: 4) {
                UsageRing(fraction: usage.contextFraction, tint: UsageTint.color(for: usage.contextFraction))
                    .frame(width: 15, height: 15)
                if usage.hasContext, usage.contextFraction >= 0.5 {
                    Text(UsageFormat.percent(usage.contextFraction))
                        .font(.orbit(.caption, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(UsageTint.color(for: usage.contextFraction))
                }
            }
            .padding(.horizontal, 5)
            .frame(minWidth: 24, minHeight: 24)
            .overlay(alignment: .topTrailing) {
                if let limit = UsageFormat.pressingLimit(usage.limits) {
                    Circle()
                        .fill(limit.isExhausted ? Color.red : Color.orange)
                        .frame(width: 6, height: 6)
                        .offset(x: -1, y: 2)
                }
            }
            .background(isHovering || isPresented ? AnyShapeStyle(Theme.subtleFill) : AnyShapeStyle(.clear), in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            UsagePopover(session: session) { isPresented = false }
        }
        .help(help)
    }

    private var help: String {
        var lines: [String] = []
        if usage.hasContext, let used = usage.contextUsed, let size = usage.contextSize {
            lines.append("Context: \(UsageFormat.percent(usage.contextFraction)) (\(UsageFormat.tokens(used)) of \(UsageFormat.tokens(size)))")
        }
        if let limit = UsageFormat.pressingLimit(usage.limits) {
            lines.append("\(limit.name): \(limit.isExhausted ? "reached" : UsageFormat.percent(limit.used ?? 1))")
        }
        return lines.isEmpty ? "Usage" : lines.joined(separator: "\n")
    }
}

struct UsageRing: View {
    let fraction: Double
    let tint: Color
    var lineWidth: CGFloat = 2.2

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.13), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(fraction, fraction > 0 ? 0.03 : 0))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(lineWidth / 2)
        .animation(.smooth, value: fraction)
    }
}

/// Context first (what the next message has room for), then the plan's
/// limits with when they reset, then what this chat cost.
private struct UsagePopover: View {
    let session: AgentSession
    let dismiss: () -> Void

    private var usage: SessionUsage { session.usage }
    private var model: String? { session.configOptions.first { $0.category == "model" }?.currentName }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 12)
            context
            Divider().padding(.vertical, 12)
            limits
            if usage.cost != nil || usage.tokens != nil {
                Divider().padding(.vertical, 12)
                thisChat
            }
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
        .onAppear { session.refreshLimits() }
    }

    private var header: some View {
        HStack(spacing: 7) {
            AgentIcon(provider: session.provider, size: 14)
            Text(model.map { "\(session.provider.name) · \($0)" } ?? session.provider.name)
                .font(.orbit(.body, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            if let plan = usage.plan {
                Text(plan)
                    .font(.orbit(.caption, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Theme.subtleFill, in: .capsule)
                    .help("Plan")
            }
        }
    }

    @ViewBuilder private var context: some View {
        sectionTitle("Context")
        if let used = usage.contextUsed, let size = usage.contextSize, usage.hasContext {
            let tint = UsageTint.color(for: usage.contextFraction)
            HStack(spacing: 14) {
                ZStack {
                    UsageRing(fraction: usage.contextFraction, tint: usage.contextFraction < 0.75 ? .accentColor : tint, lineWidth: 5)
                    Text(UsageFormat.percent(usage.contextFraction))
                        .font(.orbit(.caption, weight: .semibold))
                        .monospacedDigit()
                }
                .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(UsageFormat.tokens(used)) of \(UsageFormat.tokens(size)) tokens")
                        .font(.orbit(.body))
                    Text("\(UsageFormat.tokens(max(0, size - used))) left")
                        .font(.orbit(.caption))
                        .foregroundStyle(usage.contextFraction >= 0.75 ? AnyShapeStyle(tint) : AnyShapeStyle(.secondary))
                    if session.offers(command: "compact") {
                        Button("Compact", systemImage: "arrow.down.right.and.arrow.up.left") {
                            session.run(command: "compact")
                            dismiss()
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .disabled(session.status != .ready)
                        .help("Summarize the conversation to free the context (/compact)")
                        .padding(.top, 3)
                    }
                }
                Spacer(minLength: 0)
            }
        } else {
            placeholder("\(session.provider.name) hasn't reported its context yet.")
        }
    }

    @ViewBuilder private var limits: some View {
        HStack(alignment: .firstTextBaseline) {
            sectionTitle("Plan limits")
            Spacer(minLength: 8)
            if let updated = usage.limitsUpdatedAt {
                Text("Updated \(Text(updated, format: .relative(presentation: .named)))")
                    .font(.orbit(.caption))
                    .foregroundStyle(.tertiary)
                    .help(updated.formatted(date: .abbreviated, time: .shortened))
            }
        }
        if usage.limits.isEmpty {
            placeholder(UsageFormat.missingLimits(session.provider))
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(usage.limits) { LimitRow(limit: $0) }
            }
        }
        if let credits = usage.credits {
            row("Credits", credits).padding(.top, 10)
        }
        if session.offers(command: "status") {
            Button("Full Status", systemImage: "info.circle") {
                session.run(command: "status")
                dismiss()
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .disabled(session.status != .ready)
            .help("Ask \(session.provider.name) for its status in the chat (/status)")
            .padding(.top, 10)
        }
    }

    @ViewBuilder private var thisChat: some View {
        sectionTitle("This chat")
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
            if let cost = usage.cost {
                gridRow("Cost", cost.formatted(.currency(code: usage.currency).precision(.fractionLength(2))))
            }
            if let tokens = usage.tokens {
                gridRow("Input", UsageFormat.tokens(tokens.input))
                gridRow("Output", UsageFormat.tokens(tokens.output))
                if tokens.thought > 0 { gridRow("Reasoning", UsageFormat.tokens(tokens.thought)) }
                if tokens.cacheRead > 0 || tokens.cacheWrite > 0 {
                    gridRow("Cache", "\(UsageFormat.tokens(tokens.cacheRead)) read · \(UsageFormat.tokens(tokens.cacheWrite)) written")
                }
                gridRow("Turns", "\(usage.turns)")
            }
        }
        .font(.orbit(.body))
    }

    private func gridRow(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).monospacedDigit().gridColumnAlignment(.trailing).frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.orbit(.caption, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.bottom, 8)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).monospacedDigit()
        }
        .font(.orbit(.body))
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.orbit(.caption))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// One plan window: how much is used, when it starts over.
private struct LimitRow: View {
    let limit: SessionUsage.Limit

    var body: some View {
        // A window that ended since the agent last said starts over empty.
        let reset = limit.hasReset()
        let used = reset ? 0 : limit.used
        let tint: Color = limit.isExhausted && !reset ? .red : used.map(UsageTint.color) ?? .secondary
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(limit.name)
                Spacer(minLength: 8)
                if let used {
                    Text(limit.isExhausted && !reset ? "Reached" : UsageFormat.percent(used))
                        .monospacedDigit()
                        .foregroundStyle(tint == .secondary ? AnyShapeStyle(.secondary) : AnyShapeStyle(tint))
                }
            }
            .font(.orbit(.body))
            if let used {
                UsageBar(fraction: used, tint: tint == .secondary ? .accentColor : tint)
            }
            HStack(spacing: 4) {
                if let resetsAt = limit.resetsAt {
                    Text(UsageFormat.reset(resetsAt))
                        .help(resetsAt.formatted(date: .complete, time: .shortened))
                }
                if let note = limit.note, !reset {
                    if limit.resetsAt != nil { Text("·") }
                    Text(note).foregroundStyle(.orange)
                }
            }
            .font(.orbit(.caption))
            .foregroundStyle(.secondary)
        }
    }
}

private struct UsageBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(Color.primary.opacity(0.1))
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(tint)
                        .frame(width: fraction > 0 ? max(4, proxy.size.width * min(1, fraction)) : 0)
                }
        }
        .frame(height: 5)
    }
}

enum UsageTint {
    /// Neutral until it's worth noticing: the agent compacts or stops near the end.
    static func color(for fraction: Double) -> Color {
        switch fraction {
        case ..<0.75: .secondary
        case ..<0.9: .orange
        default: .red
        }
    }
}

enum UsageFormat {
    static func tokens(_ count: Int) -> String {
        count.formatted(.number.notation(.compactName).precision(.significantDigits(1...3)))
    }

    static func percent(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded()))%" }

    /// "Resets in 42m", "Resets in 2h 14m · 18:40", "Resets Fri 09:00".
    static func reset(_ date: Date, now: Date = Date()) -> String {
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return "Reset" }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 60 { return "Resets in \(minutes)m" }
        if seconds < 86_400 {
            return "Resets in \(minutes / 60)h \(minutes % 60)m · \(date.formatted(date: .omitted, time: .shortened))"
        }
        return "Resets \(date.formatted(.dateTime.weekday(.abbreviated).hour().minute()))"
    }

    /// The limit worth a dot on the ring: reached, or nine tenths used.
    static func pressingLimit(_ limits: [SessionUsage.Limit], now: Date = Date()) -> SessionUsage.Limit? {
        limits.filter { !$0.hasReset(at: now) && ($0.isExhausted || ($0.used ?? 0) >= 0.9) }
            .max { ($0.isExhausted ? 2 : $0.used ?? 0) < ($1.isExhausted ? 2 : $1.used ?? 0) }
    }

    @MainActor
    static func missingLimits(_ provider: AgentProvider) -> String {
        switch provider.id {
        case "claude-acp": "Claude reports its plan limits as it works: they show after its next reply."
        case "codex-acp": "Codex hasn't logged its limits yet: they show after its first reply."
        default: "\(provider.name) doesn't report plan limits."
        }
    }
}
