import OrbitUI
import SwiftUI

/// The composer's context ring; click for limits, cost and tokens.
struct UsageButton: View {
    let session: AgentSession
    @State private var isPresented = false
    @State private var isHovering = false

    private var usage: SessionUsage { session.usage }

    var body: some View {
        Button { isPresented.toggle() } label: {
            UsageRing(fraction: usage.contextFraction, tint: UsageTint.color(for: usage.contextFraction))
                .frame(width: 15, height: 15)
                .frame(width: 24, height: 24)
                .background(isHovering || isPresented ? AnyShapeStyle(Theme.subtleFill) : AnyShapeStyle(.clear), in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            UsagePopover(usage: usage, provider: session.provider.name)
        }
        .help(help)
    }

    private var help: String {
        guard usage.hasContext, let used = usage.contextUsed, let size = usage.contextSize else { return "Usage" }
        return "Context: \(Int((usage.contextFraction * 100).rounded()))% (\(UsageFormat.tokens(used)) of \(UsageFormat.tokens(size)))"
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

private struct UsagePopover: View {
    let usage: SessionUsage
    let provider: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            section("Context") {
                if let used = usage.contextUsed, let size = usage.contextSize, usage.hasContext {
                    meter(
                        title: "\(UsageFormat.tokens(used)) of \(UsageFormat.tokens(size)) tokens",
                        fraction: usage.contextFraction
                    )
                } else {
                    placeholder("\(provider) hasn't reported its context yet.")
                }
            }
            if !usage.limits.isEmpty {
                section("Plan limits") {
                    ForEach(usage.limits) { limit in
                        VStack(alignment: .leading, spacing: 5) {
                            if let used = limit.used {
                                meter(title: limit.name, fraction: used, exhausted: limit.isExhausted)
                            } else {
                                Text(limit.name).font(.orbit(.body))
                            }
                            if let resetsAt = limit.resetsAt {
                                Text("Resets \(Text(resetsAt, format: .relative(presentation: .named)))")
                                    .font(.orbit(.caption))
                                    .foregroundStyle(limit.isExhausted ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                            }
                        }
                    }
                }
            }
            if usage.cost != nil || usage.tokens != nil {
                section("This session") {
                    VStack(spacing: 4) {
                        if let cost = usage.cost {
                            row("Cost", cost.formatted(.currency(code: usage.currency).precision(.fractionLength(2))))
                        }
                        if let tokens = usage.tokens {
                            row("Input", UsageFormat.tokens(tokens.input))
                            row("Output", UsageFormat.tokens(tokens.output))
                            if tokens.thought > 0 { row("Reasoning", UsageFormat.tokens(tokens.thought)) }
                            if tokens.cacheRead > 0 || tokens.cacheWrite > 0 {
                                row("Cache", "\(UsageFormat.tokens(tokens.cacheRead)) read · \(UsageFormat.tokens(tokens.cacheWrite)) written")
                            }
                            row("Turns", "\(usage.turns)")
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 270, alignment: .leading)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.orbit(.caption, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func meter(title: String, fraction: Double, exhausted: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                Spacer(minLength: 8)
                Text("\(Int((fraction * 100).rounded()))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.orbit(.body))
            UsageBar(fraction: fraction, tint: exhausted ? .red : UsageTint.color(for: fraction))
        }
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
            .font(.orbit(.body))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
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
        .frame(height: 4)
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
}
