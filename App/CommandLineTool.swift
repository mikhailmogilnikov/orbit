import AppKit

/// `orbit .` in a terminal (D142): a small script in /usr/local/bin that hands
/// its paths to Orbit by bundle id, so it keeps working when the app moves.
@MainActor
enum CommandLineTool {
    static let path = "/usr/local/bin/orbit"

    static let script = """
    #!/bin/sh
    # Opens folders and files in Orbit: `orbit .`, `orbit ~/dev/app`, `orbit src/main.swift`.
    # Installed by Orbit → Install 'orbit' Command.
    [ $# -eq 0 ] && set -- .
    for arg in "$@"; do
      [ -e "$arg" ] || { echo "orbit: no such file or folder: $arg" >&2; exit 1; }
    done
    exec open -b \(Bundle.main.bundleIdentifier ?? "dev.orbit.app") "$@"

    """

    static var isInstalled: Bool {
        (try? String(contentsOfFile: path, encoding: .utf8)) == script
    }

    static func install() {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-\(UUID().uuidString)")
        do {
            try script.write(to: temporary, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporary.path)
        } catch {
            return report(error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        // /usr/local/bin is usually root's: macOS asks for the password then.
        if (try? FileManager.default.replaceItemAt(URL(fileURLWithPath: path), withItemAt: temporary)) == nil {
            let command = "mkdir -p /usr/local/bin && cp \(quoted(temporary.path)) \(quoted(path)) && chmod 755 \(quoted(path))"
            var error: NSDictionary?
            NSAppleScript(source: "do shell script \"\(command)\" with administrator privileges")?.executeAndReturnError(&error)
            if let error {
                // Cancelled at the password prompt: nothing to say.
                if error[NSAppleScript.errorNumber] as? Int == -128 { return }
                return report(error[NSAppleScript.errorMessage] as? String ?? "The script couldn't be copied.")
            }
        }
        let alert = NSAlert()
        alert.messageText = "The 'orbit' command is installed"
        alert.informativeText = "In a terminal, `orbit .` opens the current folder in Orbit; `orbit path/to/file` opens a file in its project."
        alert.runModal()
    }

    private static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\\\''") + "'"
    }

    private static func report(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Couldn't install the 'orbit' command"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}
