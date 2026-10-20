import AppKit
import OrbitKit
import SwiftUI

/// The first launch's tour (D205): a short film of what Orbit is (agents
/// circling a project, then an agent change kept in the editor), four steps
/// that set it up (agents, look, review keys, the `orbit` command) and a
/// closing line. Help → Welcome to Orbit plays it again.
@MainActor
@Observable
final class Onboarding {
    static let shared = Onboarding()
    private static let doneKey = "orbit.onboardingDone"

    /// The window showing it: one at a time, the first one on a first launch.
    private(set) var hostID: ObjectIdentifier?

    func windowAppeared(_ host: PluginHost) {
        guard hostID == nil, !UserDefaults.standard.bool(forKey: Self.doneKey) else { return }
        hostID = ObjectIdentifier(host)
    }

    func show(in host: PluginHost) {
        withAnimation(.easeInOut(duration: 0.6)) { hostID = ObjectIdentifier(host) }
    }

    func isShowing(in host: PluginHost) -> Bool { hostID == ObjectIdentifier(host) }

    func finish() {
        UserDefaults.standard.set(true, forKey: Self.doneKey)
        withAnimation(.easeInOut(duration: 0.9)) { hostID = nil }
    }
}

/// The film's colors: night and starlight, nothing else; only the
/// satellites have color, their agents'.
private enum Cosmos {
    static let night = Color(red: 0.012, green: 0.014, blue: 0.03)
    static let planet = Color(red: 0.03, green: 0.035, blue: 0.065)
    static let starlight = Color(red: 0.86, green: 0.9, blue: 1)
    static let claude = Color(red: 0.85, green: 0.47, blue: 0.34)
}

// MARK: - The whole thing

struct OnboardingView: View {
    let host: PluginHost
    fileprivate enum Phase { case film, setup, finale }
    @State private var phase = Phase.film

    var body: some View {
        ZStack {
            Backdrop(phase: phase)
            switch phase {
            case .film:
                IntroFilm(host: host) { advance(to: .setup) }
                    .transition(.opacity)
            case .setup:
                SetupCard(host: host) { advance(to: .finale) }
                    .transition(.scale(scale: 0.94).combined(with: .opacity))
            case .finale:
                Finale(showsHint: host.workspace.root == nil) { Onboarding.shared.finish() }
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if phase == .film {
                Button("Skip Intro") { advance(to: .setup) }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .keyboardShortcut(.cancelAction)
                    .padding(28)
                    .transition(.opacity)
            }
        }
        // Clicks stop here: the window under it waits.
        .contentShape(.rect)
        .environment(\.colorScheme, .dark)
        .ignoresSafeArea()
    }

    private func advance(to next: Phase) {
        guard next != phase else { return }
        withAnimation(.smooth(duration: 0.9)) { phase = next }
    }
}

/// Night with stars and, once the setup starts, a planet's lit edge rising
/// from the bottom: the view from orbit.
private struct Backdrop: View {
    let phase: OnboardingView.Phase
    @State private var starsShown = false

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let diameter = max(size.width * 2.4, 2000)
            let rise: CGFloat = switch phase {
            case .film: -160
            case .setup: size.height * 0.16
            case .finale: size.height * 0.3
            }
            ZStack {
                Cosmos.night
                Starfield()
                    .opacity(starsShown ? 1 : 0)
                ZStack {
                    Circle()
                        .fill(Cosmos.starlight)
                        .frame(width: diameter + 30, height: diameter + 30)
                        .blur(radius: 50)
                        .opacity(0.1)
                    Circle()
                        .strokeBorder(Cosmos.starlight.opacity(0.35), lineWidth: 1)
                        .background(Circle().fill(Cosmos.planet))
                        .frame(width: diameter, height: diameter)
                }
                .position(x: size.width / 2, y: size.height + diameter / 2 - rise)
            }
        }
        .onAppear {
            withAnimation(.easeIn(duration: 1.6)) { starsShown = true }
        }
    }
}

private struct Starfield: View {
    private struct Star {
        var x, y, size, phase, speed: Double
    }

    /// The same sky every time: a hash, not a random generator.
    private static let stars: [Star] = (0..<170).map { index in
        func noise(_ salt: Double) -> Double {
            let value = sin(Double(index) * 12.9898 + salt * 78.233) * 43758.5453
            return value - value.rounded(.down)
        }
        return Star(x: noise(1), y: noise(2), size: 0.6 + noise(3) * noise(3) * 1.8, phase: noise(4) * 6.28, speed: 0.6 + noise(5) * 1.8)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                for star in Self.stars {
                    let twinkle = 0.55 + 0.45 * sin(time * star.speed + star.phase)
                    context.opacity = twinkle * min(1, 0.25 + star.size / 2.4)
                    let rect = CGRect(x: star.x * size.width, y: star.y * size.height, width: star.size, height: star.size)
                    context.fill(Path(ellipseIn: rect), with: .color(Cosmos.starlight))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Orbits

/// Something circling on one of the rings.
private struct Satellite: Identifiable {
    let id: String
    let ring: Int
    let phase: Double
    let content: AnyView
}

private struct Ring {
    var width: CGFloat
    var ratio: CGFloat
    var tilt: Angle
    var speed: Double
}

/// One plane, nested: a system's orbits.
private let orbitRings = [
    Ring(width: 250, ratio: 0.26, tilt: .degrees(-9), speed: 0.5),
    Ring(width: 390, ratio: 0.26, tilt: .degrees(-9), speed: 0.32),
    Ring(width: 530, ratio: 0.26, tilt: .degrees(-9), speed: 0.21),
]

/// Tilted rings around a center, with satellites that pass behind it on the
/// far half of their ring.
private struct OrbitSystem<Center: View>: View {
    var scale: CGFloat = 1
    /// How much of each ring is drawn, for drawing them in.
    var drawn: CGFloat = 1
    var ringOpacity: Double = 1
    var satellites: [Satellite]
    var satelliteOpacity: Double = 1
    @ViewBuilder var center: Center

    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(orbitRings.indices, id: \.self) { index in
                    let ring = orbitRings[index]
                    Ellipse()
                        .trim(from: 0, to: drawn)
                        .stroke(
                            LinearGradient(colors: [Cosmos.starlight.opacity(0.08), Cosmos.starlight.opacity(0.3)], startPoint: .top, endPoint: .bottom),
                            lineWidth: 1
                        )
                        .frame(width: ring.width * scale, height: ring.width * ring.ratio * scale)
                        .rotationEffect(ring.tilt)
                        .opacity(ringOpacity)
                }
                center
                    .zIndex(1)
                ForEach(satellites) { satellite in
                    let place = position(of: satellite, at: time)
                    // Nearness 0…1 changes size and brightness continuously; the layer
                    // flips only at the ring's ends, where nothing overlaps.
                    let near = (place.depth + 1) / 2
                    satellite.content
                        .scaleEffect(0.72 + 0.28 * near)
                        .opacity(satelliteOpacity * (0.45 + 0.55 * near))
                        .offset(place.offset)
                        .zIndex(place.depth > 0 ? 2 : 0)
                        .transition(.scale.combined(with: .opacity))
                }
            }
        }
    }

    /// Where a satellite is, and how near: depth -1 (far side) … 1 (near side).
    private func position(of satellite: Satellite, at time: Double) -> (offset: CGSize, depth: Double) {
        let ring = orbitRings[satellite.ring % orbitRings.count]
        let theta = time * ring.speed + satellite.phase
        let a = ring.width * scale / 2
        let b = a * ring.ratio
        let x = a * cos(theta)
        let y = b * sin(theta)
        let tilt = ring.tilt.radians
        return (CGSize(width: x * cos(tilt) - y * sin(tilt), height: x * sin(tilt) + y * cos(tilt)), sin(theta))
    }
}

/// An agent's icon on a dark tile, small enough to read as a body in orbit.
private struct AgentSatellite: View {
    let item: ExtensionItem

    var body: some View {
        item.icon()
            .frame(width: 30, height: 30)
            .background(Cosmos.night, in: .rect(cornerRadius: Theme.smallCorner * 1.3, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.smallCorner * 1.3, style: .continuous).strokeBorder(Theme.hairline)
            }
    }
}

/// The agents most people come with, installed or from the ACP registry.
@MainActor
private func featuredAgents(_ host: PluginHost) -> [ExtensionItem] {
    guard let source = host.ui.extensionSources.first(where: { $0.kind == .agents }) else { return [] }
    let installed = source.installed
    let available = source.available(matching: "")
    return ["claude-acp", "codex-acp", "gemini", "cursor", "github-copilot-cli", "opencode"].compactMap { id in
        installed.first { $0.id == "agent:" + id } ?? available.first { $0.id == "agent:" + id }
    }
}

/// Fades in from a blur, rising a little.
private struct Reveal: ViewModifier {
    let shown: Bool

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .blur(radius: shown ? 0 : 12)
            .offset(y: shown ? 0 : 14)
    }
}

private extension View {
    func revealed(_ shown: Bool) -> some View { modifier(Reveal(shown: shown)) }
}

// MARK: - The film

/// Orbit's mark comes out of the dark, agents start circling it, it all
/// settles above two lines that say what it's for, and an agent change is
/// kept in a little editor. ~16 s; Skip Intro (Esc) leaves at any point.
private struct IntroFilm: View {
    let host: PluginHost
    let finish: () -> Void
    @State private var stage = 0

    /// The agents themselves circle the mark: their icons, as in the chat.
    private var satellites: [Satellite] {
        featuredAgents(host).prefix(5).enumerated().map { index, item in
            Satellite(id: item.id, ring: index % orbitRings.count, phase: Double(index) * 2.5 + 0.4, content: AnyView(AgentSatellite(item: item)))
        }
    }

    var body: some View {
        let folded = stage >= 4
        let demo = stage >= 8
        ZStack {
            OrbitSystem(
                scale: folded ? 0.44 : 1,
                drawn: stage >= 3 ? 1 : 0,
                ringOpacity: folded ? 0.7 : 1,
                satellites: stage >= 3 ? satellites : [],
                satelliteOpacity: folded ? 0.8 : 1
            ) {
                OrbitMark()
                    .foregroundStyle(.white)
                    .frame(width: 76, height: 76)
                    .scaleEffect(folded ? 1 : 1.5)
                    .opacity(stage >= 2 ? 1 : 0)
                    .blur(radius: stage >= 2 ? 0 : 20)
            }
            .offset(y: demo ? -260 : (folded ? -96 : 0))
            .blur(radius: demo ? 18 : 0)
            .opacity(demo ? 0 : 1)

            Text("Orbit")
                .font(.orbit(.display, weight: .semibold, scale: 2))
                .foregroundStyle(.white)
                .revealed(stage >= 5 && !demo)
                .offset(y: 26)
            VStack(spacing: 6) {
                Text("Agents write the code.")
                    .foregroundStyle(.white.opacity(0.62))
                    .revealed(stage >= 6 && !demo)
                Text("You decide what stays.")
                    .foregroundStyle(.white)
                    .revealed(stage >= 7 && !demo)
            }
            .font(.orbit(.display, weight: .regular))
            .offset(y: 116)

            if demo {
                VStack(spacing: 26) {
                    DiffDemo(theme: Extensions.shared.colorTheme(dark: true), mode: .film) {
                        Task {
                            try? await Task.sleep(for: .seconds(0.8))
                            finish()
                        }
                    }
                    .shadow(color: .black.opacity(0.6), radius: 40, y: 16)
                    VStack(spacing: 6) {
                        Text("Changes land right in your code.")
                            .foregroundStyle(.white)
                        Text("Keep what's good. Undo the rest.")
                            .foregroundStyle(.white.opacity(0.62))
                    }
                    .font(.orbit(.large, weight: .medium))
                }
                .transition(.scale(scale: 0.92).combined(with: .opacity))
            }
        }
        .task { await host.ui.extensionSources.first { $0.kind == .agents }?.refresh() }
        .task { await play() }
    }

    private func play() async {
        let script: [(delay: Double, stage: Int, animation: Animation)] = [
            (0.5, 2, .smooth(duration: 1.6)),
            (0.8, 3, .easeInOut(duration: 1.8)),
            (2.6, 4, .spring(duration: 1.1, bounce: 0.2)),
            (0.8, 5, .smooth(duration: 0.9)),
            (0.9, 6, .smooth(duration: 0.9)),
            (1.0, 7, .smooth(duration: 0.9)),
            (2.0, 8, .smooth(duration: 1)),
        ]
        for step in script {
            try? await Task.sleep(for: .seconds(step.delay))
            if Task.isCancelled { return }
            withAnimation(step.animation) { stage = step.stage }
        }
    }
}

// MARK: - The little editor

/// A theme's colors for the demo editor.
private struct CodePalette {
    let background, foreground, lineNumber, keyword, type, function, string, added, removed: Color
    let isDark: Bool

    init(_ theme: ColorTheme) {
        func syntax(_ capture: String, _ fallback: Color) -> Color {
            theme.style(forCapture: capture)?.color?.color ?? fallback
        }
        isDark = theme.isDark
        background = theme.editorBackground?.color ?? (theme.isDark ? Color(white: 0.11) : .white)
        foreground = theme.editorForeground?.color ?? (theme.isDark ? .white : .black)
        lineNumber = theme.lineNumber?.color ?? foreground.opacity(0.4)
        keyword = syntax("keyword", .pink)
        type = syntax("type", .teal)
        function = syntax("function", .blue)
        string = syntax("string", .orange)
        added = theme.added?.color ?? .green
        removed = theme.deleted?.color ?? .red
    }

    /// Swift, colored by a few rules: enough for the demo's lines.
    func highlighted(_ code: String) -> AttributedString {
        let keywords: Set = ["struct", "let", "func", "return", "var"]
        let types: Set = ["Greeter", "String"]
        let functions: Set = ["greet", "print"]
        var result = AttributedString()
        var index = code.startIndex
        while index < code.endIndex {
            let character = code[index]
            var end = code.index(after: index)
            var color = foreground
            if character == "\"" {
                while end < code.endIndex, code[end] != "\"" { end = code.index(after: end) }
                if end < code.endIndex { end = code.index(after: end) }
                color = string
            } else if character.isLetter {
                while end < code.endIndex, code[end].isLetter || code[end].isNumber { end = code.index(after: end) }
                let word = String(code[index..<end])
                color = keywords.contains(word) ? keyword : types.contains(word) ? type : functions.contains(word) ? function : foreground
            }
            var run = AttributedString(code[index..<end])
            run.foregroundColor = color
            result += run
            index = end
        }
        return result
    }
}

private struct DemoLine: Identifiable {
    enum Change { case none, added, removed }
    let id: Int
    let code: String
    var change = Change.none
}

/// An agent rewriting one line of a file, the change shown inline with its
/// banner, and Keep pressed. `film` plays once, `loop` again and again,
/// `still` holds the moment with the banner up.
private struct DiffDemo: View {
    enum Mode { case film, loop, still }
    let theme: ColorTheme
    let mode: Mode
    var width: CGFloat = 470
    var finished: () -> Void = {}
    @State private var step = 0

    private static let head = [
        DemoLine(id: 1, code: "struct Greeter {"),
        DemoLine(id: 2, code: "    let name: String"),
        DemoLine(id: 3, code: ""),
        DemoLine(id: 4, code: "    func greet() -> String {"),
    ]
    private static let old = DemoLine(id: 5, code: "        return \"Hello, \" + name")
    private static let new = [
        DemoLine(id: 50, code: "        let greeting = \"Hello, \\(name)!\""),
        DemoLine(id: 51, code: "        print(greeting)"),
        DemoLine(id: 52, code: "        return greeting"),
    ]
    private static let tail = [
        DemoLine(id: 6, code: "    }"),
        DemoLine(id: 7, code: "}"),
    ]

    private static func lines(at step: Int) -> [DemoLine] {
        var lines = head
        if step < 7 {
            var old = old
            if step >= 1 { old.change = .removed }
            lines.append(old)
        }
        let added = step >= 7 ? 3 : min(3, max(0, step - 1))
        lines += new.prefix(added).map { line in
            var line = line
            if step < 7 { line.change = .added }
            return line
        }
        return lines + tail
    }

    var body: some View {
        let palette = CodePalette(theme)
        let step = mode == .still ? 5 : self.step
        let lines = Self.lines(at: step)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "swift")
                    .foregroundStyle(.orange)
                Text("Greeter.swift")
                    .orbitFont(.body, weight: .medium)
                Spacer()
                if (1..<5).contains(step) {
                    HStack(spacing: 5) {
                        Image(systemName: "sparkle")
                            .foregroundStyle(Cosmos.claude)
                            .symbolEffect(.pulse)
                        Text("Claude is editing")
                    }
                    .orbitFont(.caption, weight: .medium)
                    .opacity(0.75)
                    .transition(.opacity)
                }
                if step >= 7 {
                    Label("Kept", systemImage: "checkmark")
                        .orbitFont(.caption, weight: .semibold)
                        .foregroundStyle(palette.added)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background { Rectangle().fill(palette.foreground.opacity(0.04)) }

            if (5..<7).contains(step) {
                ChangeBanner(palette: palette, pressed: step == 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.element.id) { offset, line in
                    let number = lines[..<offset].filter { $0.change != .removed }.count + 1
                    DemoLineView(line: line, number: line.change == .removed ? nil : number, palette: palette)
                }
            }
            .padding(.vertical, 8)
            Spacer(minLength: 0)
        }
        .foregroundStyle(palette.foreground)
        // Header 34 + banner 38 + ten lines (the removed one too) + padding; pinned
        // to the top so nothing taller ever shifts the header.
        .frame(width: width, height: 304, alignment: .top)
        .background(palette.background, in: .rect(cornerRadius: Theme.largeCorner, style: .continuous))
        .clipShape(.rect(cornerRadius: Theme.largeCorner, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.largeCorner, style: .continuous)
                .strokeBorder(palette.foreground.opacity(0.12))
        }
        .environment(\.colorScheme, palette.isDark ? .dark : .light)
        .task(id: mode == .still) {
            guard mode != .still else { return }
            await play()
        }
    }

    private func play() async {
        let script: [(delay: Double, step: Int)] = [(1, 1), (0.6, 2), (0.3, 3), (0.3, 4), (0.6, 5), (1.4, 6), (0.35, 7), (1.6, 8)]
        repeat {
            for item in script {
                try? await Task.sleep(for: .seconds(item.delay))
                if Task.isCancelled { return }
                withAnimation(.spring(duration: 0.45, bounce: 0.15)) { step = item.step }
            }
            if mode == .film { return finished() }
            try? await Task.sleep(for: .seconds(1))
            withAnimation(.easeInOut(duration: 0.5)) { step = 0 }
        } while !Task.isCancelled
    }
}

private struct DemoLineView: View {
    let line: DemoLine
    let number: Int?
    let palette: CodePalette

    var body: some View {
        let tint: Color? = switch line.change {
        case .none: nil
        case .added: palette.added
        case .removed: palette.removed
        }
        HStack(spacing: 0) {
            Text(number.map(String.init) ?? "")
                .foregroundStyle(palette.lineNumber)
                .frame(width: 28, alignment: .trailing)
                .padding(.trailing, 16)
            Text(palette.highlighted(line.code))
                .lineLimit(1)
                .opacity(line.change == .removed ? 0.7 : 1)
            Spacer(minLength: 0)
        }
        .font(.orbit(.code, scale: 1.12))
        .frame(height: 21)
        .background { Rectangle().fill(tint?.opacity(0.15) ?? .clear) }
        .overlay(alignment: .leading) {
            if let tint {
                Rectangle()
                    .fill(tint)
                    .frame(width: 3)
            }
        }
        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: -8)), removal: .opacity))
    }
}

/// The review banner over a changed file, as the editor shows it.
private struct ChangeBanner: View {
    let palette: CodePalette
    let pressed: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(Cosmos.claude)
            Text("1 agent change")
            Text("+3").foregroundStyle(palette.added)
            Text("−1").foregroundStyle(palette.removed)
            Spacer()
            Text("Undo")
                .padding(.horizontal, 10)
                .frame(height: 22)
                .background(palette.foreground.opacity(0.1), in: .capsule)
            HStack(spacing: 5) {
                Text("Keep")
                Text("⌥⌘↩").opacity(0.55)
            }
            .padding(.horizontal, 10)
            .frame(height: 22)
            .foregroundStyle(palette.background)
            .background(palette.foreground, in: .capsule)
            .scaleEffect(pressed ? 0.9 : 1)
            .shadow(color: pressed ? palette.foreground.opacity(0.6) : .clear, radius: 12)
        }
        .orbitFont(.body, weight: .medium)
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background { Rectangle().fill(palette.foreground.opacity(0.06)) }
    }
}

// MARK: - Setup

private enum SetupStep: Int, CaseIterable {
    case agents, look, review, terminal
}

/// The setup steps on a glass card over the horizon: a rail of segments on
/// top, what to do on the left, a live picture of it on the right.
private struct SetupCard: View {
    let host: PluginHost
    let finish: () -> Void
    @State private var step = SetupStep.agents
    @State private var forward = true

    var body: some View {
        let isLast = step == SetupStep.allCases.last
        VStack(alignment: .leading, spacing: 0) {
            StepRail(count: SetupStep.allCases.count, current: step.rawValue)
            ZStack {
                switch step {
                case .agents: AgentsStep(host: host)
                case .look: LookStep()
                case .review: ReviewStep(host: host)
                case .terminal: TerminalStep()
                }
            }
            .id(step)
            .transition(.asymmetric(
                insertion: .modifier(active: StepShift(x: forward ? 32 : -32), identity: StepShift(x: 0)),
                removal: .modifier(active: StepShift(x: forward ? -32 : 32), identity: StepShift(x: 0))
            ))
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
            .padding(.top, 28)
            HStack {
                if step == .agents {
                    Button("Skip Setup", action: finish)
                        .buttonStyle(.glass)
                } else {
                    Button("Back") { move(by: -1) }
                        .buttonStyle(.glass)
                }
                Spacer()
                Text("\(step.rawValue + 1) of \(SetupStep.allCases.count)")
                    .orbitFont(.body)
                    .foregroundStyle(.tertiary)
                    .contentTransition(.numericText())
                    .padding(.trailing, 10)
                Button(isLast ? "Finish" : "Continue") {
                    if isLast { finish() } else { move(by: 1) }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding(.top, 20)
        }
        .padding(30)
        .frame(width: 860, height: 560)
        .glassEffect(.regular.tint(Cosmos.night.opacity(0.45)), in: .rect(cornerRadius: Theme.panelCorner * 1.5, style: .continuous))
        .shadow(color: .black.opacity(0.5), radius: 50, y: 20)
    }

    private func move(by delta: Int) {
        guard let next = SetupStep(rawValue: step.rawValue + delta) else { return }
        forward = delta > 0
        withAnimation(.smooth(duration: 0.28)) { step = next }
    }
}

/// A step sliding in or out: shifted, blurred and faded the further it is from rest.
private struct StepShift: ViewModifier {
    let x: CGFloat

    func body(content: Content) -> some View {
        let away = min(1, abs(x) / 32)
        content
            .offset(x: x)
            .blur(radius: 12 * away)
            .opacity(1 - away)
    }
}

/// Segments, lit up to the current step.
private struct StepRail: View {
    let count: Int
    let current: Int
    private let spacing: CGFloat = 6

    var body: some View {
        GeometryReader { geometry in
            let segment = (geometry.size.width - spacing * CGFloat(count - 1)) / CGFloat(count)
            let lit = segment * CGFloat(current + 1) + spacing * CGFloat(current)
            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.activeFill)
                Rectangle()
                    .fill(.primary)
                    .frame(width: lit)
            }
            .mask {
                HStack(spacing: spacing) {
                    ForEach(0..<count, id: \.self) { _ in Capsule() }
                }
            }
            .animation(.smooth(duration: 0.6), value: current)
        }
        .frame(height: 4)
    }
}

/// A step: title, what it's about and its controls on the left; its
/// picture on the right.
private struct StepLayout<Controls: View, Preview: View>: View {
    let title: String
    let message: LocalizedStringKey
    @ViewBuilder var controls: Controls
    @ViewBuilder var preview: Preview

    var body: some View {
        HStack(alignment: .top, spacing: 30) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.orbit(.display, weight: .bold))
                Text(message)
                    .orbitFont(.title)
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                controls
                    .padding(.top, 22)
                Spacer(minLength: 0)
            }
            .frame(width: 340, alignment: .leading)
            preview
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .background(Theme.subtleFill, in: .rect(cornerRadius: Theme.panelCorner, style: .continuous))
                .clipShape(.rect(cornerRadius: Theme.panelCorner, style: .continuous))
        }
    }
}

// MARK: Agents

/// The agents most people come with, from the ACP registry; any other one
/// is in Settings → Extensions. Each added agent joins the orbit on the right.
private struct AgentsStep: View {
    let host: PluginHost

    var body: some View {
        let source = host.ui.extensionSources.first { $0.kind == .agents }
        let installed = source?.installed ?? []
        let rows = featuredAgents(host)
        StepLayout(
            title: "Agents",
            message: "Orbit runs the coding agents you already use, side by side. Add the ones you want; dozens more are in Settings → Extensions."
        ) {
            if let source {
                VStack(spacing: 2) {
                    ForEach(rows) { AgentRow(item: $0) }
                }
                if rows.isEmpty {
                    if source.isLoading {
                        ProgressView().controlSize(.small)
                    } else if let error = source.loadError {
                        Label("The agent list didn't load: \(error)", systemImage: "wifi.exclamationmark")
                            .orbitFont(.body)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Label("The Agents plugin is off. Turn it on in Settings → Extensions.", systemImage: "puzzlepiece.extension")
                    .orbitFont(.body)
                    .foregroundStyle(.secondary)
            }
        } preview: {
            AgentOrbit(items: installed)
        }
        .task { await source?.refresh() }
    }
}

private struct AgentRow: View {
    let item: ExtensionItem

    var body: some View {
        HStack(spacing: 12) {
            item.icon()
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .orbitFont(.control, weight: .semibold)
                Text(item.failure ?? item.warning ?? item.summary)
                    .orbitFont(.caption)
                    .foregroundStyle(item.failure != nil || item.warning != nil ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .help(item.failure ?? item.warning ?? item.summary)
            }
            Spacer(minLength: 8)
            if item.isBusy {
                ProgressView()
                    .controlSize(.small)
            } else if item.isInstalled {
                Image(systemName: "checkmark.circle.fill")
                    .orbitFont(.title)
                    .foregroundStyle(Theme.added)
                    .help("Added")
                    .transition(.scale.combined(with: .opacity))
            } else if let install = item.install {
                Button("Get") { Task { await install() } }
                    .buttonStyle(.glass)
                    .help("Download \(item.name) from the ACP registry")
            }
        }
        .padding(.vertical, 5)
        .animation(.spring(duration: 0.4), value: item.isInstalled)
    }
}

/// Orbit's mark with the installed agents circling it.
private struct AgentOrbit: View {
    let items: [ExtensionItem]

    var body: some View {
        let satellites = items.prefix(8).enumerated().map { index, item in
            Satellite(
                id: item.id, ring: index % orbitRings.count, phase: Double(index) * 2.3 + 0.6,
                content: AnyView(AgentSatellite(item: item))
            )
        }
        ZStack {
            OrbitSystem(scale: 0.74, satellites: satellites) {
                OrbitMark()
                    .foregroundStyle(.white)
                    .frame(width: 54, height: 54)
                    .shadow(color: Cosmos.starlight.opacity(0.5), radius: 20)
            }
            .animation(.spring(duration: 0.7, bounce: 0.3), value: items.map(\.id))
            if items.isEmpty {
                Text("Agents you add will circle here")
                    .orbitFont(.body)
                    .foregroundStyle(.tertiary)
                    .offset(y: 150)
            }
        }
    }
}

// MARK: Look

/// Light, dark or following the Mac, and a color theme: the installed ones
/// and the most downloaded of Zed's catalog, shown on the demo on hover.
private struct LookStep: View {
    @State private var hovered: ColorTheme?

    var body: some View {
        let preferences = Preferences.shared
        let extensions = Extensions.shared
        let dark = preferences.isDark
        StepLayout(
            title: "Appearance",
            message: "Light, dark or following your Mac, and a color theme for the code. Try others any time with ⌃⌘T."
        ) {
            HStack(spacing: 14) {
                ForEach(Preferences.Appearance.allCases, id: \.self) { appearance in
                    AppearanceTile(appearance: appearance, isSelected: preferences.appearance == appearance) {
                        withAnimation(.smooth) { preferences.appearance = appearance }
                    }
                }
            }
            Text("Theme")
                .orbitFont(.body, weight: .semibold)
                .foregroundStyle(.secondary)
                .padding(.top, 22)
                .padding(.bottom, 8)
            ThemeChoices(dark: dark, hovered: $hovered)
        } preview: {
            DiffDemo(theme: hovered ?? extensions.colorTheme(dark: dark), mode: .still, width: 400)
                .animation(.smooth(duration: 0.3), value: hovered?.id)
        }
        .task { ExtensionCatalog.shared.loadThemeCatalog() }
    }
}

private struct AppearanceTile: View {
    let appearance: Preferences.Appearance
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                ZStack {
                    switch appearance {
                    case .light: WindowSketch(dark: false)
                    case .dark: WindowSketch(dark: true)
                    case .system:
                        WindowSketch(dark: false)
                            .overlay { WindowSketch(dark: true).mask(alignment: .trailing) { Rectangle().frame(width: 44) } }
                    }
                }
                .frame(width: 88, height: 58)
                .clipShape(.rect(cornerRadius: Theme.corner, style: .continuous))
                .padding(3)
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.corner + 3, style: .continuous)
                        .strokeBorder(isSelected ? Color.white : .clear, lineWidth: 2)
                }
                Text(appearance.rawValue.capitalized)
                    .orbitFont(.body, weight: isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
    }
}

/// A window in a few shapes, light or dark, like System Settings' appearance picker.
private struct WindowSketch: View {
    let dark: Bool

    var body: some View {
        let base = dark ? Color(white: 0.13) : Color(white: 0.96)
        let line = dark ? Color(white: 0.32) : Color(white: 0.8)
        HStack(spacing: 0) {
            (dark ? Color(white: 0.18) : Color(white: 0.9))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 5) {
                Capsule().fill(Color(nsColor: .systemBlue)).frame(width: 30, height: 4)
                Capsule().fill(line).frame(width: 40, height: 4)
                Capsule().fill(line).frame(width: 22, height: 4)
                Capsule().fill(line).frame(width: 34, height: 4)
            }
            .padding(9)
            Spacer(minLength: 0)
        }
        .background(base)
    }
}

/// Installed themes first, then catalog favourites to fill six places.
private struct ThemeChoices: View {
    let dark: Bool
    @Binding var hovered: ColorTheme?

    var body: some View {
        let extensions = Extensions.shared
        let catalog = ExtensionCatalog.shared
        let picked = extensions.pickedColorTheme(dark: dark)
        let families = Dictionary(grouping: extensions.colorThemes, by: \.extensionID)
            .values
            .compactMap { family in family.first { $0.isDark == dark } ?? family.first }
            .sorted { ($0.extensionID == picked.extensionID ? 0 : 1, $0.name) < ($1.extensionID == picked.extensionID ? 0 : 1, $1.name) }
        let installedIDs = Set(extensions.installed.map(\.id))
        let extra = catalog.themeCatalog.filter { !installedIDs.contains($0.id) }.prefix(max(0, 6 - families.count))
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
            ForEach(families.prefix(6)) { theme in
                ThemeChip(name: theme.extensionName == "Orbit" ? theme.name : theme.extensionName, theme: theme, isSelected: theme.extensionID == picked.extensionID, isBusy: false, hovered: $hovered) {
                    extensions.choose(theme)
                }
            }
            ForEach(Array(extra)) { entry in
                let sample = catalog.samples[entry.id].flatMap { themes in themes.first { $0.isDark == dark } ?? themes.first }
                ThemeChip(name: entry.name, theme: sample, isSelected: false, isBusy: catalog.busy.contains(entry.id), hovered: $hovered) {
                    Task { await catalog.install(entry, pick: true) }
                }
                .onAppear { catalog.requestSample(entry) }
            }
        }
    }
}

private struct ThemeChip: View {
    let name: String
    let theme: ColorTheme?
    let isSelected: Bool
    let isBusy: Bool
    @Binding var hovered: ColorTheme?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                ThemeSwatch(theme: theme)
                Text(name)
                    .orbitFont(.body, weight: isSelected ? .semibold : .regular)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isBusy {
                    ProgressView().controlSize(.mini)
                } else if isSelected {
                    Image(systemName: "checkmark")
                        .orbitFont(.caption, weight: .bold)
                }
            }
            .padding(6)
            .background(isSelected ? Theme.activeFill : Theme.subtleFill, in: .rect(cornerRadius: Theme.corner, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside, let theme { hovered = theme } else if !inside, hovered?.id == theme?.id { hovered = nil }
        }
    }
}

/// A theme's background with three of its syntax colors.
private struct ThemeSwatch: View {
    let theme: ColorTheme?

    var body: some View {
        let palette = theme.map(CodePalette.init)
        HStack(spacing: 2) {
            ForEach(Array([palette?.keyword, palette?.string, palette?.function].enumerated()), id: \.offset) { _, color in
                Circle().fill(color ?? Theme.activeFill).frame(width: 5, height: 5)
            }
        }
        .frame(width: 26, height: 20)
        .background(palette?.background ?? Theme.subtleFill, in: .rect(cornerRadius: Theme.smallCorner, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.smallCorner, style: .continuous).strokeBorder(Theme.hairline)
        }
    }
}

// MARK: Review

/// The keys of reviewing, read from the commands so a rebound key shows as rebound.
private struct ReviewStep: View {
    let host: PluginHost

    var body: some View {
        StepLayout(
            title: "Reviewing changes",
            message: "Agents write straight to disk; their changes show up in the editor in green and red. Walk through them and keep what's good."
        ) {
            VStack(spacing: 10) {
                row("Keep a change", "checkmark", "editor.keepChange", "⌥⌘↩")
                row("Undo a change", "arrow.uturn.backward", "editor.undoChange", "⌥⌘⌫")
                row("Next change", "arrow.down", "editor.nextChange", "⌥⌘↓")
                row("Keep everything", "checkmark.circle", "review.acceptAll", "⇧⌘↩")
                row("Ask an agent to edit the selection", "wand.and.sparkles", "editor.inlineEdit", "⌘K")
                row("Chat with an agent", "bubble.left.and.text.bubble.right", "agents.focus", "⌘L")
            }
        } preview: {
            DiffDemo(theme: Extensions.shared.colorTheme(dark: true), mode: .loop, width: 400)
        }
    }

    private func row(_ title: String, _ symbol: String, _ command: String, _ fallback: String) -> some View {
        let shortcut = host.commands.all.first { $0.id == command }?.displayShortcut?.displayString ?? fallback
        return HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(title)
                .orbitFont(.control)
            Spacer(minLength: 8)
            KeyCaps(shortcut)
        }
    }
}

// MARK: Terminal

private struct TerminalStep: View {
    @State private var isInstalled = CommandLineTool.isInstalled

    var body: some View {
        StepLayout(
            title: "The orbit command",
            message: "Add the `orbit` command: `orbit .` opens the folder you're in, `orbit src/app.ts` a file in its project."
        ) {
            if isInstalled {
                Label("The orbit command is installed", systemImage: "checkmark.circle.fill")
                    .orbitFont(.control, weight: .medium)
                    .foregroundStyle(Theme.added)
            } else {
                Button("Install 'orbit' Command…") {
                    CommandLineTool.install()
                    withAnimation { isInstalled = CommandLineTool.isInstalled }
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                Text("A small script in /usr/local/bin. macOS may ask for your password.")
                    .orbitFont(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 8)
            }
        } preview: {
            TerminalDemo()
        }
    }
}

/// `orbit .` typed in a terminal, and a window opening for it.
private struct TerminalDemo: View {
    private static let command = "orbit ."
    @State private var typed = 0
    @State private var opened = false

    var body: some View {
        VStack(spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { _ in Circle().fill(Theme.activeFill).frame(width: 9, height: 9) }
                }
                .padding(.bottom, 6)
                HStack(spacing: 0) {
                    Text("~/dev/my-app ").foregroundStyle(.secondary)
                    Text("❯ ").foregroundStyle(Theme.added)
                    Text(Self.command.prefix(typed))
                    Rectangle()
                        .fill(Cosmos.starlight)
                        .frame(width: 7, height: 15)
                        .opacity(opened ? 0 : 0.8)
                }
                Text("Opening my-app in Orbit…")
                    .foregroundStyle(.secondary)
                    .opacity(opened ? 1 : 0)
            }
            .font(.orbit(.code, scale: 1.2))
            .padding(16)
            .frame(width: 330, alignment: .leading)
            .background(Cosmos.night, in: .rect(cornerRadius: Theme.largeCorner, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.largeCorner, style: .continuous).strokeBorder(Theme.hairline)
            }

            HStack(spacing: 10) {
                OrbitMark()
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                Text("my-app")
                    .orbitFont(.title, weight: .semibold)
                Spacer()
                Image(systemName: "sparkles").foregroundStyle(Cosmos.claude)
            }
            .padding(14)
            .frame(width: 240)
            .glassEffect(.regular, in: .rect(cornerRadius: Theme.largeCorner, style: .continuous))
            .scaleEffect(opened ? 1 : 0.6)
            .opacity(opened ? 1 : 0)
            .blur(radius: opened ? 0 : 8)
        }
        .task { await play() }
    }

    private func play() async {
        repeat {
            try? await Task.sleep(for: .seconds(0.8))
            for count in 1...Self.command.count {
                try? await Task.sleep(for: .milliseconds(110))
                if Task.isCancelled { return }
                typed = count
            }
            try? await Task.sleep(for: .seconds(0.5))
            withAnimation(.spring(duration: 0.6, bounce: 0.3)) { opened = true }
            try? await Task.sleep(for: .seconds(2.6))
            if Task.isCancelled { return }
            withAnimation(.easeInOut(duration: 0.4)) {
                opened = false
                typed = 0
            }
        } while !Task.isCancelled
    }
}

// MARK: - Finale

/// One line, a glint of light passing over it, then the window underneath.
private struct Finale: View {
    let showsHint: Bool
    let finish: () -> Void
    @State private var shown = false
    @State private var sweep: CGFloat = 0

    var body: some View {
        let font = Font.orbit(.display, weight: .semibold, scale: 1.7)
        VStack(spacing: 16) {
            Text("Your agents are in orbit.")
                .font(font)
                .foregroundStyle(.white.opacity(0.7))
                .overlay {
                    GeometryReader { geometry in
                        let width = geometry.size.width
                        LinearGradient(colors: [.clear, .white, .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: width * 0.5)
                            .offset(x: -width * 0.5 + sweep * width * 1.5)
                    }
                    .mask { Text("Your agents are in orbit.").font(font) }
                }
                .revealed(shown)
            if showsHint {
                Text("Open a folder to begin.")
                    .orbitFont(.large)
                    .foregroundStyle(.secondary)
                    .revealed(shown)
            }
        }
        .task {
            withAnimation(.smooth(duration: 1.1)) { shown = true }
            withAnimation(.easeInOut(duration: 2.2).delay(0.3)) { sweep = 1 }
            try? await Task.sleep(for: .seconds(3.4))
            if !Task.isCancelled { finish() }
        }
    }
}
