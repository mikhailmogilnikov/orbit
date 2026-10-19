import Foundation
@testable import OrbitEditor
import Testing

@Suite struct MergeConflictTests {
    let text = """
    keep
    <<<<<<< HEAD
    mine 1
    mine 2
    =======
    theirs
    >>>>>>> feature/login
    middle
    <<<<<<< HEAD
    a
    ||||||| base
    o
    =======
    b
    >>>>>>> other
    """

    @Test func findsBlocksWithLabelsAndDiff3Base() {
        let conflicts = MergeConflicts.find(in: text.components(separatedBy: "\n"))
        #expect(conflicts.count == 2)
        #expect(conflicts[0] == MergeConflict(start: 1, current: 2..<4, base: nil, separator: 4, incoming: 5..<6, end: 6,
                                               currentLabel: "HEAD", incomingLabel: "feature/login"))
        #expect(conflicts[1].base == 11..<12)
        #expect(conflicts[1].current == 9..<10)
        #expect(conflicts[1].incoming == 13..<14)
        // Unfinished or stray markers aren't conflicts.
        #expect(MergeConflicts.find(in: ["<<<<<<< HEAD", "x", "======="]).isEmpty)
        #expect(MergeConflicts.find(in: ["<<<<<<<<< not a marker", "=======", ">>>>>>> x"]).isEmpty)
    }

    @Test func resolvingReplacesTheWholeBlock() {
        let ns = text as NSString
        let conflicts = MergeConflicts.find(in: text.components(separatedBy: "\n"))
        func apply(_ edit: LineEditing.Edit) -> String { ns.replacingCharacters(in: edit.range, with: edit.replacement) }
        #expect(apply(MergeConflicts.edit(ns, conflict: conflicts[0], choice: .current)).hasPrefix("keep\nmine 1\nmine 2\nmiddle\n<<<<<<<"))
        #expect(apply(MergeConflicts.edit(ns, conflict: conflicts[0], choice: .both)).hasPrefix("keep\nmine 1\nmine 2\ntheirs\nmiddle\n"))
        // The last block, at the end of the file without a newline after it.
        #expect(apply(MergeConflicts.edit(ns, conflict: conflicts[1], choice: .incoming)).hasSuffix("middle\nb"))
    }
}
