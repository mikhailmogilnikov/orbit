import Foundation
@testable import OrbitAPI
@testable import OrbitTerminal
import Testing

/// Problems read from real output of each runner (D220), captured with colors
/// on (`FORCE_COLOR=1`) and the project's path put in.
@Suite struct RunnerProblemTests {
    private func project(_ files: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("runners-\(UUID().uuidString)")
        for file in files {
            let url = root.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "".write(to: url, atomically: true, encoding: .utf8)
        }
        return root.standardizedFileURL
    }

    private func problems(_ output: String, in root: URL) -> [(file: String, line: Int, column: Int, severity: Diagnostic.Severity, message: String)] {
        var parser = TaskOutputParser(directories: [root])
        parser.feed(Array(output.utf8))
        return parser.problems.flatMap { url, diagnostics in
            diagnostics.map { (String(url.path.dropFirst(root.path.count + 1)), $0.range.start.line + 1, $0.range.start.character + 1, $0.severity, $0.message) }
        }.sorted { ($0.file, $0.line) < ($1.file, $1.line) }
    }

    @Test func viteDevServer() throws {
        let root = try project(["src/bad.ts", "index.html"])
        let output = """

          \u{1B}[32m\u{1B}[1mVITE\u{1B}[22m v7.1.3\u{1B}[39m  \u{1B}[2mready in \u{1B}[0m\u{1B}[1m71\u{1B}[22m\u{1B}[2m\u{1B}[0m ms\u{1B}[22m

          \u{1B}[32m➜\u{1B}[39m  \u{1B}[1mLocal\u{1B}[22m:   \u{1B}[36mhttp://localhost:\u{1B}[1m5199\u{1B}[22m/\u{1B}[39m
        \u{1B}[2m  \u{1B}[32m➜\u{1B}[39m  \u{1B}[1mNetwork\u{1B}[22m\u{1B}[2m: use \u{1B}[22m\u{1B}[1m--host\u{1B}[22m\u{1B}[2m to expose\u{1B}[22m
        \u{1B}[31m(!) Failed to run dependency scan. Skipping dependency pre-bundling. Error: \u{1B}[31m  Failed to scan for dependencies from entries:
          \(root.path)/index.html

          \u{1B}[31m\u{1B}[31m✘ \u{1B}[41;31m[\u{1B}[41;97mERROR\u{1B}[41;31m]\u{1B}[0m \u{1B}[1mExpected ";" but found "y"\u{1B}[0m

            src/bad.ts:1:8:
        \u{1B}[37m      1 │ const x \u{1B}[32my\u{1B}[37m = 1
                │         \u{1B}[32m^\u{1B}[37m
                ╵         \u{1B}[32m;\u{1B}[0m


            at new Promise (<anonymous>)
        \u{1B}[2m8:44:31 PM\u{1B}[22m \u{1B}[31m\u{1B}[1m[vite]\u{1B}[22m\u{1B}[39m \u{1B}[31mInternal server error: Transform failed with 1 error:
        \(root.path)/src/bad.ts:1:8: ERROR: Expected ";" but found "y"\u{1B}[39m
          Plugin: \u{1B}[35mvite:esbuild\u{1B}[39m
          File: \u{1B}[36m\(root.path)/src/bad.ts\u{1B}[39m:1:8
        \u{1B}[33m  
          \u{1B}[33mExpected ";" but found "y"\u{1B}[33m
          1  |  const x y = 1
             |          ^
          2  |  export default x
          3  |  
          \u{1B}[39m
              at Socket.emit (node:events:514:28)
              at addChunk (node:internal/streams/readable:569:12)
              at readableAddChunkPushByteMode (node:internal/streams/readable:520:3)
              at Readable.push (node:internal/streams/readable:400:5)
              at Pipe.onStreamRead (node:internal/stream_base_commons:194:23)
        \u{1B}[2m8:44:31 PM\u{1B}[22m \u{1B}[31m\u{1B}[1m[vite]\u{1B}[22m\u{1B}[39m \u{1B}[31m\u{1B}[2m(client)\u{1B}[22m\u{1B}[39m Pre-transform error: Transform failed with 1 error:
        \(root.path)/src/bad.ts:1:8: ERROR: Expected ";" but found "y"
          Plugin: \u{1B}[35mvite:esbuild\u{1B}[39m
          File: \u{1B}[36m\(root.path)/src/bad.ts\u{1B}[39m:1:8
        \u{1B}[33m  
          \u{1B}[33mExpected ";" but found "y"\u{1B}[33m
          1  |  const x y = 1
             |          ^
          2  |  export default x
          3  |  
          \u{1B}[39m

        """
        let found = problems(output, in: root)
        // esbuild's block (the dependency scan) and the server's error: one problem, esbuild's message.
        #expect(found.count == 1)
        #expect(found.first?.file == "src/bad.ts")
        #expect(found.first?.line == 1)
        #expect(found.first?.column == 8)
        #expect(found.first?.message == #"Expected ";" but found "y""#)
    }

    @Test func viteBuild() throws {
        let root = try project(["src/bad.ts"])
        let output = """
        \u{1B}[36mvite v7.1.3 \u{1B}[32mbuilding for production...\u{1B}[36m\u{1B}[39m
        transforming...
        \u{1B}[32m✓\u{1B}[39m 3 modules transformed.
        \u{1B}[31m✗\u{1B}[39m Build failed in 27ms
        \u{1B}[31merror during build:
        \u{1B}[31m[vite:esbuild] Transform failed with 1 error:
        \(root.path)/src/bad.ts:1:8: ERROR: Expected ";" but found "y"\u{1B}[31m
        file: \u{1B}[36m\(root.path)/src/bad.ts:1:8\u{1B}[31m
        \u{1B}[33m
        \u{1B}[33mExpected ";" but found "y"\u{1B}[33m
        1  |  const x y = 1
           |          ^
        2  |  export default x
        3  |  
        \u{1B}[31m
            at Socket.emit (node:events:514:28)
            at addChunk (node:internal/streams/readable:569:12)
            at readableAddChunkPushByteMode (node:internal/streams/readable:520:3)
            at Readable.push (node:internal/streams/readable:400:5)
            at Pipe.onStreamRead (node:internal/stream_base_commons:194:23)\u{1B}[39m

        """
        let found = problems(output, in: root)
        #expect(found.count == 1)
        #expect(found.first.map { "\($0.file):\($0.line):\($0.column) \($0.message)" } == #"src/bad.ts:1:8 Expected ";" but found "y""#)
    }

    @Test func jest() throws {
        let root = try project(["tests/sum.test.js"])
        let output = """
        \u{1B}[0m\u{1B}[7m\u{1B}[1m\u{1B}[31m FAIL \u{1B}[39m\u{1B}[22m\u{1B}[27m\u{1B}[0m \u{1B}[2mtests/\u{1B}[22m\u{1B}[1msum.test.js\u{1B}[22m
          \u{1B}[31m✕\u{1B}[39m \u{1B}[2madds (1 ms)\u{1B}[22m
          \u{1B}[31m✕\u{1B}[39m \u{1B}[2mthrows\u{1B}[22m

        \u{1B}[1m\u{1B}[31m  \u{1B}[1m● \u{1B}[22m\u{1B}[1madds\u{1B}[39m\u{1B}[22m

            \u{1B}[2mexpect(\u{1B}[22m\u{1B}[31mreceived\u{1B}[39m\u{1B}[2m).\u{1B}[22mtoBe\u{1B}[2m(\u{1B}[22m\u{1B}[32mexpected\u{1B}[39m\u{1B}[2m) // Object.is equality\u{1B}[22m

            Expected: \u{1B}[32m4\u{1B}[39m
            Received: \u{1B}[31m3\u{1B}[39m
        \u{1B}[2m\u{1B}[22m
        \u{1B}[2m    \u{1B}[0m \u{1B}[90m 2 |\u{1B}[39m\u{1B}[22m
        \u{1B}[2m     \u{1B}[90m 3 |\u{1B}[39m test(\u{1B}[32m'adds'\u{1B}[39m\u{1B}[33m,\u{1B}[39m () \u{1B}[33m=>\u{1B}[39m {\u{1B}[22m
        \u{1B}[2m    \u{1B}[31m\u{1B}[1m>\u{1B}[22m\u{1B}[2m\u{1B}[39m\u{1B}[90m 4 |\u{1B}[39m   expect(sum(\u{1B}[35m1\u{1B}[39m\u{1B}[33m,\u{1B}[39m \u{1B}[35m2\u{1B}[39m))\u{1B}[33m.\u{1B}[39mtoBe(\u{1B}[35m4\u{1B}[39m)\u{1B}[22m
        \u{1B}[2m     \u{1B}[90m   |\u{1B}[39m                     \u{1B}[31m\u{1B}[1m^\u{1B}[22m\u{1B}[2m\u{1B}[39m\u{1B}[22m
        \u{1B}[2m     \u{1B}[90m 5 |\u{1B}[39m })\u{1B}[22m
        \u{1B}[2m     \u{1B}[90m 6 |\u{1B}[39m\u{1B}[22m
        \u{1B}[2m     \u{1B}[90m 7 |\u{1B}[39m test(\u{1B}[32m'throws'\u{1B}[39m\u{1B}[33m,\u{1B}[39m () \u{1B}[33m=>\u{1B}[39m {\u{1B}[0m\u{1B}[22m
        \u{1B}[2m\u{1B}[22m
        \u{1B}[2m      \u{1B}[2mat Object.toBe (\u{1B}[22m\u{1B}[2m\u{1B}[0m\u{1B}[36mtests/sum.test.js\u{1B}[39m\u{1B}[0m\u{1B}[2m:4:21)\u{1B}[22m\u{1B}[2m\u{1B}[22m

        \u{1B}[1m\u{1B}[31m  \u{1B}[1m● \u{1B}[22m\u{1B}[1mthrows\u{1B}[39m\u{1B}[22m

            boom
        \u{1B}[2m\u{1B}[22m
        \u{1B}[2m    \u{1B}[0m \u{1B}[90m  6 |\u{1B}[39m\u{1B}[22m
        \u{1B}[2m     \u{1B}[90m  7 |\u{1B}[39m test(\u{1B}[32m'throws'\u{1B}[39m\u{1B}[33m,\u{1B}[39m () \u{1B}[33m=>\u{1B}[39m {\u{1B}[22m
        \u{1B}[2m    \u{1B}[31m\u{1B}[1m>\u{1B}[22m\u{1B}[2m\u{1B}[39m\u{1B}[90m  8 |\u{1B}[39m   \u{1B}[36mthrow\u{1B}[39m \u{1B}[36mnew\u{1B}[39m \u{1B}[33mError\u{1B}[39m(\u{1B}[32m'boom'\u{1B}[39m)\u{1B}[22m
        \u{1B}[2m     \u{1B}[90m    |\u{1B}[39m         \u{1B}[31m\u{1B}[1m^\u{1B}[22m\u{1B}[2m\u{1B}[39m\u{1B}[22m
        \u{1B}[2m     \u{1B}[90m  9 |\u{1B}[39m })\u{1B}[22m
        \u{1B}[2m     \u{1B}[90m 10 |\u{1B}[39m\u{1B}[0m\u{1B}[22m
        \u{1B}[2m\u{1B}[22m
        \u{1B}[2m      \u{1B}[2mat Object.<anonymous> (\u{1B}[22m\u{1B}[2m\u{1B}[0m\u{1B}[36mtests/sum.test.js\u{1B}[39m\u{1B}[0m\u{1B}[2m:8:9)\u{1B}[22m\u{1B}[2m\u{1B}[22m

        \u{1B}[1mTest Suites: \u{1B}[22m\u{1B}[1m\u{1B}[31m1 failed\u{1B}[39m\u{1B}[22m, 1 total
        \u{1B}[1mTests:       \u{1B}[22m\u{1B}[1m\u{1B}[31m2 failed\u{1B}[39m\u{1B}[22m, 2 total
        \u{1B}[1mSnapshots:   \u{1B}[22m0 total
        \u{1B}[1mTime:\u{1B}[22m        0.115 s
        \u{1B}[2mRan all test suites\u{1B}[22m\u{1B}[2m matching \u{1B}[22mtests/sum.test.js\u{1B}[2m.\u{1B}[22m

        """
        let found = problems(output, in: root)
        #expect(found.map { "\($0.file):\($0.line):\($0.column)" } == ["tests/sum.test.js:4:21", "tests/sum.test.js:8:9"])
        #expect(found.map(\.message) == ["adds: expect(received).toBe(expected) // Object.is equality", "throws: boom"])
    }

    @Test func vitest() throws {
        let root = try project(["tests/sum.vitest.test.js"])
        let output = """

        \u{1B}[1m\u{1B}[46m RUN \u{1B}[49m\u{1B}[22m \u{1B}[36mv3.2.4 \u{1B}[39m\u{1B}[90m\(root.path)\u{1B}[39m

         \u{1B}[31m❯\u{1B}[39m tests/sum.vitest.test.js \u{1B}[2m(\u{1B}[22m\u{1B}[2m2 tests\u{1B}[22m\u{1B}[2m | \u{1B}[22m\u{1B}[31m2 failed\u{1B}[39m\u{1B}[2m)\u{1B}[22m\u{1B}[32m 4\u{1B}[2mms\u{1B}[22m\u{1B}[39m
        \u{1B}[31m   \u{1B}[31m×\u{1B}[31m adds\u{1B}[39m\u{1B}[32m 3\u{1B}[2mms\u{1B}[22m\u{1B}[39m
        \u{1B}[31m     → expected 3 to be 4 // Object.is equality\u{1B}[39m
        \u{1B}[31m   \u{1B}[31m×\u{1B}[31m throws\u{1B}[39m\u{1B}[32m 0\u{1B}[2mms\u{1B}[22m\u{1B}[39m
        \u{1B}[31m     → boom\u{1B}[39m

        \u{1B}[31m⎯⎯⎯⎯⎯⎯⎯\u{1B}[39m\u{1B}[1m\u{1B}[41m Failed Tests 2 \u{1B}[49m\u{1B}[22m\u{1B}[31m⎯⎯⎯⎯⎯⎯⎯\u{1B}[39m

        \u{1B}[41m\u{1B}[1m FAIL \u{1B}[22m\u{1B}[49m tests/sum.vitest.test.js\u{1B}[2m > \u{1B}[22madds
        \u{1B}[31m\u{1B}[1mAssertionError\u{1B}[22m: expected 3 to be 4 // Object.is equality\u{1B}[39m

        \u{1B}[32m- Expected\u{1B}[39m
        \u{1B}[31m+ Received\u{1B}[39m

        \u{1B}[32m- 4\u{1B}[39m
        \u{1B}[31m+ 3\u{1B}[39m

        \u{1B}[36m \u{1B}[2m❯\u{1B}[22m tests/sum.vitest.test.js:\u{1B}[2m5:21\u{1B}[22m\u{1B}[39m
            \u{1B}[90m  3| \u{1B}[39m
            \u{1B}[90m  4| \u{1B}[39m\u{1B}[34mtest\u{1B}[39m(\u{1B}[32m'adds'\u{1B}[39m\u{1B}[33m,\u{1B}[39m () \u{1B}[33m=>\u{1B}[39m {
            \u{1B}[90m  5| \u{1B}[39m  \u{1B}[34mexpect\u{1B}[39m(\u{1B}[34msum\u{1B}[39m(\u{1B}[34m1\u{1B}[39m\u{1B}[33m,\u{1B}[39m \u{1B}[34m2\u{1B}[39m))\u{1B}[33m.\u{1B}[39m\u{1B}[34mtoBe\u{1B}[39m(\u{1B}[34m4\u{1B}[39m)
            \u{1B}[90m   | \u{1B}[39m                    \u{1B}[31m^\u{1B}[39m
            \u{1B}[90m  6| \u{1B}[39m})
            \u{1B}[90m  7| \u{1B}[39m

        \u{1B}[31m\u{1B}[2m⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯[1/2]⎯\u{1B}[22m\u{1B}[39m

        \u{1B}[41m\u{1B}[1m FAIL \u{1B}[22m\u{1B}[49m tests/sum.vitest.test.js\u{1B}[2m > \u{1B}[22mthrows
        \u{1B}[31m\u{1B}[1mError\u{1B}[22m: boom\u{1B}[39m
        \u{1B}[36m \u{1B}[2m❯\u{1B}[22m tests/sum.vitest.test.js:\u{1B}[2m9:9\u{1B}[22m\u{1B}[39m
            \u{1B}[90m  7| \u{1B}[39m
            \u{1B}[90m  8| \u{1B}[39m\u{1B}[34mtest\u{1B}[39m(\u{1B}[32m'throws'\u{1B}[39m\u{1B}[33m,\u{1B}[39m () \u{1B}[33m=>\u{1B}[39m {
            \u{1B}[90m  9| \u{1B}[39m  \u{1B}[35mthrow\u{1B}[39m \u{1B}[35mnew\u{1B}[39m \u{1B}[33mError\u{1B}[39m(\u{1B}[32m'boom'\u{1B}[39m)
            \u{1B}[90m   | \u{1B}[39m        \u{1B}[31m^\u{1B}[39m
            \u{1B}[90m 10| \u{1B}[39m})
            \u{1B}[90m 11| \u{1B}[39m

        \u{1B}[31m\u{1B}[2m⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯[2/2]⎯\u{1B}[22m\u{1B}[39m


        \u{1B}[2m Test Files \u{1B}[22m \u{1B}[1m\u{1B}[31m1 failed\u{1B}[39m\u{1B}[22m\u{1B}[90m (1)\u{1B}[39m
        \u{1B}[2m      Tests \u{1B}[22m \u{1B}[1m\u{1B}[31m2 failed\u{1B}[39m\u{1B}[22m\u{1B}[90m (2)\u{1B}[39m
        \u{1B}[2m   Start at \u{1B}[22m 20:45:12
        \u{1B}[2m   Duration \u{1B}[22m 189ms\u{1B}[2m (transform 10ms, setup 0ms, collect 6ms, tests 4ms, environment 0ms, prepare 46ms)\u{1B}[22m


        """
        let found = problems(output, in: root)
        #expect(found.map { "\($0.file):\($0.line):\($0.column)" } == ["tests/sum.vitest.test.js:5:21", "tests/sum.vitest.test.js:9:9"])
        #expect(found.map(\.message) == ["adds: AssertionError: expected 3 to be 4 // Object.is equality", "throws: Error: boom"])
    }

    @Test func pythonTracebackPointsAtTheProjectsDeepestFrame() throws {
        let root = try project(["main.py", "lib.py", "syntax.py"])
        let output = """
        Traceback (most recent call last):
          File \u{1B}[35m"\(root.path)/main.py"\u{1B}[0m, line \u{1B}[35m3\u{1B}[0m, in \u{1B}[35m<module>\u{1B}[0m
            \u{1B}[31mload\u{1B}[0m\u{1B}[1;31m("{bad")\u{1B}[0m
            \u{1B}[31m~~~~\u{1B}[0m\u{1B}[1;31m^^^^^^^^\u{1B}[0m
          File \u{1B}[35m"\(root.path)/lib.py"\u{1B}[0m, line \u{1B}[35m4\u{1B}[0m, in \u{1B}[35mload\u{1B}[0m
            return \u{1B}[31mjson.loads\u{1B}[0m\u{1B}[1;31m(text)\u{1B}[0m
                   \u{1B}[31m~~~~~~~~~~\u{1B}[0m\u{1B}[1;31m^^^^^^\u{1B}[0m
          File \u{1B}[35m"/Users/mikhailmogilnikov/.pyenv/versions/3.13.1/lib/python3.13/json/__init__.py"\u{1B}[0m, line \u{1B}[35m346\u{1B}[0m, in \u{1B}[35mloads\u{1B}[0m
            return \u{1B}[31m_default_decoder.decode\u{1B}[0m\u{1B}[1;31m(s)\u{1B}[0m
                   \u{1B}[31m~~~~~~~~~~~~~~~~~~~~~~~\u{1B}[0m\u{1B}[1;31m^^^\u{1B}[0m
          File \u{1B}[35m"/Users/mikhailmogilnikov/.pyenv/versions/3.13.1/lib/python3.13/json/decoder.py"\u{1B}[0m, line \u{1B}[35m345\u{1B}[0m, in \u{1B}[35mdecode\u{1B}[0m
            obj, end = \u{1B}[31mself.raw_decode\u{1B}[0m\u{1B}[1;31m(s, idx=_w(s, 0).end())\u{1B}[0m
                       \u{1B}[31m~~~~~~~~~~~~~~~\u{1B}[0m\u{1B}[1;31m^^^^^^^^^^^^^^^^^^^^^^^\u{1B}[0m
          File \u{1B}[35m"/Users/mikhailmogilnikov/.pyenv/versions/3.13.1/lib/python3.13/json/decoder.py"\u{1B}[0m, line \u{1B}[35m361\u{1B}[0m, in \u{1B}[35mraw_decode\u{1B}[0m
            obj, end = \u{1B}[31mself.scan_once\u{1B}[0m\u{1B}[1;31m(s, idx)\u{1B}[0m
                       \u{1B}[31m~~~~~~~~~~~~~~\u{1B}[0m\u{1B}[1;31m^^^^^^^^\u{1B}[0m
        \u{1B}[1;35mjson.decoder.JSONDecodeError\u{1B}[0m: \u{1B}[35mExpecting property name enclosed in double quotes: line 1 column 2 (char 1)\u{1B}[0m

          File \u{1B}[35m"\(root.path)/syntax.py"\u{1B}[0m, line \u{1B}[35m1\u{1B}[0m
            def f(\u{1B}[1;31m:\u{1B}[0m
                  \u{1B}[1;31m^\u{1B}[0m
        \u{1B}[1;35mSyntaxError\u{1B}[0m: \u{1B}[35minvalid syntax\u{1B}[0m

        """
        let found = problems(output, in: root)
        #expect(found.map { "\($0.file):\($0.line)" } == ["lib.py:4", "syntax.py:1"])
        #expect(found.map(\.message) == [
            "JSONDecodeError: Expecting property name enclosed in double quotes: line 1 column 2 (char 1)",
            "SyntaxError: invalid syntax",
        ])
    }

    @Test func pytestInBothTracebackStyles() throws {
        let root = try project(["test_a.py"])
        for output in ["""
        \u{1B}[31mF\u{1B}[0m\u{1B}[31mF\u{1B}[0m\u{1B}[31m                                                                       [100%]\u{1B}[0m
        =================================== FAILURES ===================================
        \u{1B}[31m\u{1B}[1m___________________________________ test_eq ____________________________________\u{1B}[0m

            \u{1B}[0m\u{1B}[94mdef\u{1B}[39;49;00m\u{1B}[90m \u{1B}[39;49;00m\u{1B}[92mtest_eq\u{1B}[39;49;00m():\u{1B}[90m\u{1B}[39;49;00m
        >       \u{1B}[94massert\u{1B}[39;49;00m \u{1B}[94m1\u{1B}[39;49;00m + \u{1B}[94m1\u{1B}[39;49;00m == \u{1B}[94m3\u{1B}[39;49;00m\u{1B}[90m\u{1B}[39;49;00m
        \u{1B}[1m\u{1B}[31mE       assert (1 + 1) == 3\u{1B}[0m

        \u{1B}[1m\u{1B}[31mtest_a.py\u{1B}[0m:2: AssertionError
        \u{1B}[31m\u{1B}[1m__________________________________ test_raise __________________________________\u{1B}[0m

            \u{1B}[0m\u{1B}[94mdef\u{1B}[39;49;00m\u{1B}[90m \u{1B}[39;49;00m\u{1B}[92mtest_raise\u{1B}[39;49;00m():\u{1B}[90m\u{1B}[39;49;00m
        >       \u{1B}[94mraise\u{1B}[39;49;00m \u{1B}[96mValueError\u{1B}[39;49;00m(\u{1B}[33m"\u{1B}[39;49;00m\u{1B}[33mnope\u{1B}[39;49;00m\u{1B}[33m"\u{1B}[39;49;00m)\u{1B}[90m\u{1B}[39;49;00m
        \u{1B}[1m\u{1B}[31mE       ValueError: nope\u{1B}[0m

        \u{1B}[1m\u{1B}[31mtest_a.py\u{1B}[0m:5: ValueError
        \u{1B}[36m\u{1B}[1m=========================== short test summary info ============================\u{1B}[0m
        \u{1B}[31mFAILED\u{1B}[0m test_a.py::\u{1B}[1mtest_eq\u{1B}[0m - assert (1 + 1) == 3
        \u{1B}[31mFAILED\u{1B}[0m test_a.py::\u{1B}[1mtest_raise\u{1B}[0m - ValueError: nope
        \u{1B}[31m\u{1B}[31m\u{1B}[1m2 failed\u{1B}[0m\u{1B}[31m in 0.02s\u{1B}[0m\u{1B}[0m

        """, """
        \u{1B}[31mF\u{1B}[0m\u{1B}[31mF\u{1B}[0m\u{1B}[31m                                                                       [100%]\u{1B}[0m
        =================================== FAILURES ===================================
        \u{1B}[31m\u{1B}[1m___________________________________ test_eq ____________________________________\u{1B}[0m
        \u{1B}[1m\u{1B}[31mtest_a.py\u{1B}[0m:2: in test_eq
            \u{1B}[0m\u{1B}[94massert\u{1B}[39;49;00m \u{1B}[94m1\u{1B}[39;49;00m + \u{1B}[94m1\u{1B}[39;49;00m == \u{1B}[94m3\u{1B}[39;49;00m\u{1B}[90m\u{1B}[39;49;00m
        \u{1B}[1m\u{1B}[31mE   assert (1 + 1) == 3\u{1B}[0m
        \u{1B}[31m\u{1B}[1m__________________________________ test_raise __________________________________\u{1B}[0m
        \u{1B}[1m\u{1B}[31mtest_a.py\u{1B}[0m:5: in test_raise
            \u{1B}[0m\u{1B}[94mraise\u{1B}[39;49;00m \u{1B}[96mValueError\u{1B}[39;49;00m(\u{1B}[33m"\u{1B}[39;49;00m\u{1B}[33mnope\u{1B}[39;49;00m\u{1B}[33m"\u{1B}[39;49;00m)\u{1B}[90m\u{1B}[39;49;00m
        \u{1B}[1m\u{1B}[31mE   ValueError: nope\u{1B}[0m
        \u{1B}[36m\u{1B}[1m=========================== short test summary info ============================\u{1B}[0m
        \u{1B}[31mFAILED\u{1B}[0m test_a.py::\u{1B}[1mtest_eq\u{1B}[0m - assert (1 + 1) == 3
        \u{1B}[31mFAILED\u{1B}[0m test_a.py::\u{1B}[1mtest_raise\u{1B}[0m - ValueError: nope
        \u{1B}[31m\u{1B}[31m\u{1B}[1m2 failed\u{1B}[0m\u{1B}[31m in 0.02s\u{1B}[0m\u{1B}[0m

        """] {
            let found = problems(output, in: root)
            #expect(found.map { "\($0.file):\($0.line) \($0.message)" } == ["test_a.py:2 assert (1 + 1) == 3", "test_a.py:5 ValueError: nope"])
        }
    }

    @Test func pythonWarningsAndStrayLinesStayApart() throws {
        let root = try project(["app.py"])
        let output = """
        \(root.path)/app.py:3: DeprecationWarning: datetime.utcnow() is deprecated
          File "\(root.path)/app.py", line 9
        Starting server…
        [vite] hmr update /src/App.vue
          File: \(root.path)/app.py:1:1
        """
        let found = problems(output, in: root)
        #expect(found.count == 1)
        #expect(found.first?.severity == .warning)
        #expect(found.first?.line == 3)
    }
}
