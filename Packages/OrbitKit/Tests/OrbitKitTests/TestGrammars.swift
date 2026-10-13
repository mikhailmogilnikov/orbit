import Foundation
@testable import OrbitAPI
@testable import OrbitEditor

/// Languages for highlighting tests, installed from the catalog as the app
/// does it (D71): fetched and compiled once into the temp folder, then
/// reused. The first run needs the network and Xcode's clang.
enum TestGrammars {
    static let store = GrammarStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("orbit-grammar-installs"))
    private static let lock = NSLock()

    struct Missing: Error, CustomStringConvertible {
        var description: String
    }

    /// Installs `names` (and makes them what embedded layers find) and returns the first.
    static func grammar(_ names: String...) throws -> Grammar {
        try names.map(install).first!
    }

    @discardableResult
    static func install(_ name: String) throws -> Grammar {
        lock.lock()
        defer { lock.unlock() }
        let catalog = GrammarCatalog.shared
        guard let language = catalog.languages.first(where: { $0.name == name }), let repository = catalog.grammar(of: language) else {
            throw Missing(description: "no language \(name) in the catalog")
        }
        let installed = try store.installed(language.id).flatMap { $0.isCurrent(language, repository) ? $0 : nil }
            ?? store.install(language, grammar: repository)
        InstalledGrammars.current.withLock { grammars in
            grammars.removeAll { $0.name == installed.name }
            grammars.append(installed)
        }
        return Grammar(installed: installed)
    }
}
