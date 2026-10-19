import SwiftUI

/// The commit graph beside the history (D136): each commit gets a lane, and
/// each row says which lines cross it — straight through, or bending into
/// or out of the commit's dot.
struct GitGraphRow: Equatable, Sendable {
    /// The commit's lane.
    var column: Int
    /// Lines from the row's top: (lane at the top, lane at the middle).
    var top: [(Int, Int)]
    /// Lines to the row's bottom: (lane at the middle, lane at the bottom).
    var bottom: [(Int, Int)]
    /// Lanes running on below the row (for the expanded files under it).
    var continuing: [Int]
    var laneCount: Int

    static func == (a: GitGraphRow, b: GitGraphRow) -> Bool {
        a.column == b.column && a.laneCount == b.laneCount && a.continuing == b.continuing
            && a.top.map { [$0.0, $0.1] } == b.top.map { [$0.0, $0.1] }
            && a.bottom.map { [$0.0, $0.1] } == b.bottom.map { [$0.0, $0.1] }
    }
}

enum GitGraph {
    /// Rows for commits in topological order, newest first.
    static func rows(_ commits: [GitCommit]) -> [GitGraphRow] {
        var lanes: [String?] = []
        var rows: [GitGraphRow] = []
        rows.reserveCapacity(commits.count)
        for commit in commits {
            let before = lanes
            let column = before.firstIndex(of: commit.hash) ?? {
                if let free = lanes.firstIndex(of: nil) { return free }
                lanes.append(nil)
                return lanes.count - 1
            }()
            var top: [(Int, Int)] = []
            for (lane, expected) in before.enumerated() where expected != nil {
                top.append((lane, expected == commit.hash ? column : lane))
            }
            for lane in lanes.indices where lanes[lane] == commit.hash { lanes[lane] = nil }

            var bottom: [(Int, Int)] = []
            for (index, parent) in commit.parents.enumerated() {
                if let existing = lanes.firstIndex(of: parent) {
                    bottom.append((column, existing))
                } else if index == 0 {
                    lanes[column] = parent
                    bottom.append((column, column))
                } else {
                    let free = lanes.firstIndex(of: nil) ?? lanes.count
                    if free == lanes.count { lanes.append(parent) } else { lanes[free] = parent }
                    bottom.append((column, free))
                }
            }
            for (lane, expected) in lanes.enumerated() where expected != nil && lane < before.count
                && before[lane] == expected && expected != commit.hash {
                bottom.append((lane, lane))
            }
            while let last = lanes.last, last == nil { lanes.removeLast() }
            rows.append(GitGraphRow(
                column: column, top: top, bottom: bottom,
                continuing: lanes.indices.filter { lanes[$0] != nil },
                laneCount: max(before.count, lanes.count, column + 1)
            ))
        }
        return rows
    }

    static let colors: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .yellow, .red]
    static func color(_ lane: Int) -> Color { colors[lane % colors.count] }
}

/// One row's piece of the graph, drawn to the row's full height. Lines that
/// change lanes bend with vertical ends, so they meet the next row's straight
/// on; merges are rings, the checked-out commit a dot with a halo (D156).
struct GitGraphCell: View {
    let row: GitGraphRow?
    /// Lanes passing a row that isn't a commit (an expanded file).
    var passing: [Int] = []
    let width: CGFloat
    let spacing: CGFloat
    var isMerge = false
    var isHead = false

    var body: some View {
        Canvas { context, size in
            let x = { (lane: Int) in spacing / 2 + CGFloat(lane) * spacing }
            let middle = size.height / 2
            let lineWidth: CGFloat = 1.6
            func line(from: CGPoint, to: CGPoint, lane: Int) {
                var path = Path()
                path.move(to: from)
                if from.x == to.x {
                    path.addLine(to: to)
                } else {
                    let bend = (to.y - from.y) * 0.85
                    path.addCurve(to: to, control1: CGPoint(x: from.x, y: from.y + bend), control2: CGPoint(x: to.x, y: to.y - bend))
                }
                context.stroke(path, with: .color(GitGraph.color(lane)), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            }
            guard let row else {
                for lane in passing { line(from: CGPoint(x: x(lane), y: 0), to: CGPoint(x: x(lane), y: size.height), lane: lane) }
                return
            }
            for (from, to) in row.top { line(from: CGPoint(x: x(from), y: 0), to: CGPoint(x: x(to), y: middle), lane: from) }
            for (from, to) in row.bottom { line(from: CGPoint(x: x(from), y: middle), to: CGPoint(x: x(to), y: size.height), lane: to) }
            let color = GitGraph.color(row.column)
            let center = CGPoint(x: x(row.column), y: middle)
            func circle(_ radius: CGFloat) -> Path {
                Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            }
            if isHead {
                context.fill(circle(6), with: .color(color.opacity(0.3)))
            }
            if isMerge {
                // A ring: the background shows through, so it reads as "joins two lines".
                context.blendMode = .copy
                context.fill(circle(4), with: .color(.clear))
                context.blendMode = .normal
                context.stroke(circle(3.4), with: .color(color), lineWidth: 1.8)
            } else {
                context.fill(circle(4), with: .color(color))
            }
        }
        .frame(width: width)
        .clipped()
    }
}
