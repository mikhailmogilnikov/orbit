// Launches an app a few times and measures: time to first window, memory footprint of every
// process it owns after it settles, process count, CPU time spent while idle.
// usage: bench <label> <app path> <runs> <settle s> <idle s> [-- open args...]
import AppKit
import CoreGraphics
import Foundation

let args = CommandLine.arguments
let label = args[1], app = args[2]
let runs = Int(args[3])!, settle = Double(args[4])!, idle = Double(args[5])!
let extra = args.firstIndex(of: "--").map { Array(args[($0 + 1)...]) } ?? []

struct Proc { let pid: Int32; let ppid: Int32; let cpu: Double; let path: String; let command: String }
/// Agent processes (and what they start) are left out when BENCH_EXCLUDE matches their command line.
let exclude = ProcessInfo.processInfo.environment["BENCH_EXCLUDE"]

func shell(_ path: String, _ a: [String]) -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = a
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
    try! p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

func procs() -> [Proc] {
    let commands = Dictionary(shell("/bin/ps", ["-axww", "-o", "pid=,command="]).split(separator: "\n").compactMap { line -> (Int32, String)? in
        let f = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard f.count == 2, let pid = Int32(f[0]) else { return nil }
        return (pid, String(f[1]))
    }, uniquingKeysWith: { a, _ in a })
    return shell("/bin/ps", ["-axww", "-o", "pid=,ppid=,time=,comm="]).split(separator: "\n").compactMap { line in
        let f = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        guard f.count == 4 else { return nil }
        let t = f[2].split(separator: ":").map { Double($0) ?? 0 }
        let cpu = t.count == 2 ? t[0] * 60 + t[1] : t.count == 3 ? t[0] * 3600 + t[1] * 60 + t[2] : 0
        let pid = Int32(f[0])!
        return Proc(pid: pid, ppid: Int32(f[1])!, cpu: cpu, path: String(f[3]), command: commands[pid] ?? "")
    }
}

/// Everything launched from the bundle, plus every descendant of those (language servers, git…).
func tree(_ all: [Proc]) -> [Proc] {
    var owned = Set(all.filter { $0.path.hasPrefix(app) }.map(\.pid))
    var grew = true
    while grew {
        grew = false
        for p in all where !owned.contains(p.pid) && owned.contains(p.ppid) {
            if let exclude, p.command.range(of: exclude, options: .regularExpression) != nil { continue }
            owned.insert(p.pid); grew = true
        }
    }
    return all.filter { owned.contains($0.pid) }
}

func quitAll() {
    for _ in 0..<40 {
        let t = tree(procs())
        if t.isEmpty { return }
        for p in t where p.path.hasPrefix(app) && !tree(procs()).contains(where: { $0.pid == p.ppid }) { kill(p.pid, SIGTERM) }
        usleep(250_000)
    }
    for p in tree(procs()) { kill(p.pid, SIGKILL) }
    usleep(500_000)
}

func firstWindow() -> Bool {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
    for w in list {
        guard (w[kCGWindowLayer as String] as? Int) == 0,
              let pid = w[kCGWindowOwnerPID as String] as? Int32,
              let b = w[kCGWindowBounds as String] as? [String: Double],
              (b["Width"] ?? 0) >= 400, (b["Height"] ?? 0) >= 300,
              let path = NSRunningApplication(processIdentifier: pid)?.executableURL?.path,
              path.hasPrefix(app) else { continue }
        return true
    }
    return false
}

func footprint(_ pids: [Int32]) -> Double {
    let out = shell("/usr/bin/footprint", ["-f", "bytes", "--noCategories"] + pids.flatMap { ["-p", String($0)] })
    return out.split(separator: "\n").filter { $0.contains("phys_footprint:") }
        .compactMap { Double($0.split(separator: " ").dropFirst().first ?? "") }.reduce(0, +)
}

quitAll()
sleep(2)
var rows: [String] = []
for run in 0...runs {  // run 0 warms the caches and a fresh profile, and isn't counted
    let t0 = Date()
    _ = shell("/usr/bin/open", ["-n", "-a", app] + (extra.isEmpty ? [] : ["--args"] + extra))
    while !firstWindow() {
        if Date().timeIntervalSince(t0) > 60 { print("\(label) run \(run): no window"); break }
        usleep(5_000)
    }
    let launch = Date().timeIntervalSince(t0) * 1000
    Thread.sleep(forTimeInterval: settle)
    let before = tree(procs())
    let mem = footprint(before.map(\.pid)) / 1_048_576
    Thread.sleep(forTimeInterval: idle)
    let after = tree(procs())
    let cpu = after.map(\.cpu).reduce(0, +) - before.filter { p in after.contains { $0.pid == p.pid } }.map(\.cpu).reduce(0, +)
    let row = String(format: "%@\t%d\t%.0f\t%.0f\t%d\t%.2f", label, run, launch, mem, before.count, cpu)
    print(row); fflush(stdout)
    if run > 0 { rows.append(row) }
    quitAll()
    sleep(3)
}
