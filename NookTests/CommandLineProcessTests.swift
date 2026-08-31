import Darwin
import Foundation
import Testing
@testable import Nook

/// These exercise real local pipes and children, never an installed provider,
/// network connection, credential store, or real note. Short injected limits
/// keep a broken child from holding up the test suite for an action deadline.
@Suite(.serialized)
struct CommandLineProcessTests {
    private static let roomy = CommandLineProcessLimits(
        stdoutBytes: 1_024 * 1_024, stderrBytes: 256 * 1_024, timeout: 3
    )

    @Test
    func noteTextTravelsOnlyThroughStdinAndReturnsByteForByte() async throws {
        let note = Data("  café e\u{301}\n$(touch never-run) `id`; $HOME\n\n".utf8)
        let result = try await run(URL(fileURLWithPath: "/bin/cat"), input: note)
        #expect(result.stdout == note)
        #expect(result.stderr.isEmpty)
        #expect(result.exitStatus == 0)
    }

    @Test
    func simultaneousLargeInputAndBothOutputPipesDoNotDeadlock() async throws {
        let fixture = try ProcessFixture(script: """
            /bin/dd if=/dev/zero bs=16384 count=8 2>/dev/null
            (/bin/dd if=/dev/zero bs=16384 count=8 2>/dev/null) >&2
            /bin/cat
            """)
        defer { fixture.remove() }
        let input = Data(String(repeating: "Exact café e\u{301}\n", count: 20_000).utf8)
        let result = try await run(fixture.executable, input: input)
        #expect(result.stdout == Data(repeating: 0, count: 131_072) + input)
        #expect(result.stderr == Data(repeating: 0, count: 131_072))
        #expect(result.exitStatus == 0)
    }

    @Test(arguments: [false, true])
    func exceedingEitherOutputLimitRefusesTheWholeResponse(stderr: Bool) async throws {
        let fixture = try ProcessFixture(script:
            "(/bin/dd if=/dev/zero bs=16384 count=4 2>/dev/null) \(stderr ? ">&2" : "")"
        )
        defer { fixture.remove() }
        let limits = CommandLineProcessLimits(stdoutBytes: 1_024, stderrBytes: 1_024, timeout: 3)
        await #expect(throws: CommandLineProcessError.outputLimit) {
            try await run(fixture.executable, limits: limits)
        }
    }

    @Test
    func exactlyTheOutputLimitIsAcceptedWithoutTruncation() async throws {
        let bytes = Data(repeating: 120, count: 16_384)
        let limits = CommandLineProcessLimits(stdoutBytes: bytes.count, stderrBytes: 0, timeout: 3)
        let result = try await run(URL(fileURLWithPath: "/bin/cat"), input: bytes, limits: limits)
        #expect(result.stdout == bytes)
    }

    @Test
    func anEndlessStderrFloodCannotStarveTheLimitWhileInputIsBlocked() async throws {
        let fixture = try ProcessFixture(script: """
            trap '' TERM
            printf '%s' "$$" > "$0.pid"
            while :; do printf 'synthetic diagnostic flood\\n' >&2; done
            """)
        defer { fixture.remove() }
        let limits = CommandLineProcessLimits(stdoutBytes: 1_024, stderrBytes: 1_024, timeout: 3)
        let start = ContinuousClock.now
        await #expect(throws: CommandLineProcessError.outputLimit) {
            try await run(fixture.executable, input: Data(repeating: 120, count: 1_024 * 1_024), limits: limits)
        }
        #expect(start.duration(to: .now) < .seconds(2))
        let pid = try fixture.pid()
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }

    @Test
    func aChildThatNeverReadsItsInputAndIgnoresTermCannotOutliveTheDeadline() async throws {
        let fixture = try ProcessFixture(script: """
            trap '' TERM
            printf '%s' "$$" > "$0.pid"
            exec /bin/sleep 30
            """)
        defer { fixture.remove() }
        // Give the test host scheduling headroom, then prove the helper is
        // alive with TERM ignored before observing the real deadline. A 150ms
        // timeout could previously fire before the script wrote its marker
        // during a full parallel suite, testing launch delay instead of cleanup.
        let limits = CommandLineProcessLimits(stdoutBytes: 1_024, stderrBytes: 1_024, timeout: 3)
        let clock = ContinuousClock()
        let start = clock.now
        let request = Task {
            try await run(fixture.executable, input: Data(repeating: 120, count: 1_024 * 1_024), limits: limits)
        }
        try await fixture.waitForMarker("pid")
        let pid = try fixture.pid()
        #expect(kill(pid, 0) == 0)
        await #expect(throws: CommandLineProcessError.timedOut) { try await request.value }
        #expect(start.duration(to: clock.now) < .seconds(5))
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }

    @Test
    func cancellationStopsAndReapsAChildThatIgnoresTerm() async throws {
        let fixture = try ProcessFixture(script: """
            trap '' TERM
            printf '%s' "$$" > "$0.pid"
            exec /bin/sleep 30
            """)
        defer { fixture.remove() }
        let request = Task { try await run(fixture.executable) }
        try await fixture.waitForMarker("pid")
        let start = ContinuousClock.now
        request.cancel()
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(start.duration(to: .now) < .seconds(2))
        let pid = try fixture.pid()
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }

    @Test
    func cancellationBeforeEntryNeverLaunchesTheExecutable() async throws {
        let fixture = try ProcessFixture(script: "printf launched > \"$0.ran\"")
        defer { fixture.remove() }
        let gate = AsyncStream<Void>.makeStream()
        let request = Task {
            for await _ in gate.stream { break }
            return try await run(fixture.executable)
        }
        request.cancel()
        gate.continuation.finish()
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(!fixture.markerExists("ran"))
    }

    @Test
    func aDescendantHoldingPipesAfterItsLeaderExitsIsStopped() async throws {
        let fixture = try ProcessFixture(script: """
            (trap '' TERM; exec /bin/sleep 30) &
            printf '%s' "$!" > "$0.pid"
            exit 0
            """)
        defer { fixture.remove() }
        let start = ContinuousClock.now
        await #expect(throws: CommandLineProcessError.incompleteOutput) {
            try await run(fixture.executable)
        }
        #expect(start.duration(to: .now) < .seconds(2))
        // The descendant is reaped by its new parent after the group kill.
        // Nook can waitpid only its own direct child.
        let pid = try fixture.pid()
        for _ in 0..<100 where kill(pid, 0) == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }

    @Test
    func aSuccessfulLeaderCannotLeaveABackgroundHelperRunning() async throws {
        let fixture = try ProcessFixture(script: """
            (trap '' TERM; exec /bin/sleep 30) </dev/null >/dev/null 2>&1 &
            printf '%s' "$!" > "$0.pid"
            printf finished
            exit 0
            """)
        defer { fixture.remove() }
        let result = try await run(fixture.executable)
        #expect(result.exitStatus == 0)
        #expect(result.stdout == Data("finished".utf8))
        let pid = try fixture.pid()
        for _ in 0..<100 where kill(pid, 0) == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }

    @Test
    func aBrokenStdinPipeDoesNotCrashOrAcceptAPartialNote() async throws {
        let fixture = try ProcessFixture(script: "exec 0<&-; printf partial; /bin/sleep 0.1")
        defer { fixture.remove() }
        await #expect(throws: CommandLineProcessError.incompleteInput) {
            try await run(fixture.executable, input: Data(repeating: 120, count: 1_024 * 1_024))
        }
    }

    @Test
    func aMissingExecutableFailsBeforeAnyPipeWorkCanHang() async {
        await #expect(throws: CommandLineProcessError.launchFailed) {
            try await run(URL(fileURLWithPath: "/nonexistent-nook-synthetic-helper"))
        }
    }

    @Test
    func aNulInAnArgumentCannotSilentlyChangeTheCommand() async {
        await #expect(throws: CommandLineProcessError.launchFailed) {
            try await run(URL(fileURLWithPath: "/bin/echo"), arguments: ["before\0after"])
        }
    }

    @Test
    func onlyTheAccountPathTemporaryDirectoryAndLocaleEnterTheChildEnvironment() async throws {
        let expected = CommandLineAssistant.environment
        #expect(Set(expected.keys) == ["HOME", "USER", "LOGNAME", "PATH", "TMPDIR", "LANG", "LC_ALL"])
        #expect(expected["HOME"] == NSHomeDirectory())
        #expect(expected["LANG"] == "en_US.UTF-8")
        let result = try await run(URL(fileURLWithPath: "/usr/bin/env"))
        let actual = Set(String(decoding: result.stdout, as: UTF8.self).split(separator: "\n").map(String.init))
        #expect(actual == Set(expected.map { "\($0.key)=\($0.value)" }))
    }

    @Test
    func theWorkingDirectoryIsTemporaryAndUnrelatedDescriptorsAreNotInherited() async throws {
        let fixture = try ProcessFixture(script: "/bin/pwd; /bin/test ! -e /dev/fd/99")
        defer { fixture.remove() }
        let descriptor = open(fixture.directory.appendingPathComponent("unrelated").path, O_CREAT | O_RDWR, 0o600)
        #expect(descriptor >= 0)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        // Reserve a fresh descriptor, not a fixed number that the test host
        // might already use. Explicitly clear CLOEXEC to exercise spawn's rule.
        let inherited = fcntl(descriptor, F_DUPFD, 100)
        #expect(inherited >= 100)
        guard inherited >= 100 else { return }
        defer { close(inherited) }
        try fixture.replace(script: "/bin/pwd; /bin/test ! -e /dev/fd/\(inherited)")
        let result = try await run(fixture.executable)
        #expect(result.exitStatus == 0)
        let directory = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(URL(fileURLWithPath: directory).resolvingSymlinksInPath().standardizedFileURL
                == URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().standardizedFileURL)
    }

    private func run(
        _ executable: URL,
        arguments: [String] = [],
        input: Data = Data(),
        limits: CommandLineProcessLimits = Self.roomy
    ) async throws -> CommandLineProcessResult {
        try await CommandLineProcessRunner.run(
            executable: executable, arguments: arguments, input: input,
            environment: CommandLineAssistant.environment, limits: limits
        )
    }
}

struct CommandLineAssistantProcessTests {
    private static let validHelp = """
          --safe-mode
          --tools
          --strict-mcp-config
          --permission-mode
          --no-session-persistence
        """

    @Test(arguments: [false, true])
    func oversizedHelpNeverHandsTheNoteToTheAction(stderr: Bool) async throws {
        let fixture = try ProcessFixture(script: """
            if [ "$1" = '--help' ]; then
              (/bin/dd if=/dev/zero bs=16384 count=4 2>/dev/null) \(stderr ? ">&2" : "")
              exit 0
            fi
            printf ran > "$0.ran"
            /bin/cat
            """)
        defer { fixture.remove() }
        let assistant = CommandLineAssistant(
            executables: [.claude: fixture.executable],
            helpLimits: CommandLineProcessLimits(stdoutBytes: 1_024, stderrBytes: 1_024, timeout: 3)
        )
        do {
            _ = try await assistant.run(.tidy, on: "Synthetic private note", using: .claude)
            Issue.record("Oversized help must refuse the action.")
        } catch NoteAssistantError.unsupportedVersion(let engine) {
            #expect(engine == .claude)
        }
        #expect(!fixture.markerExists("ran"))
    }

    @Test
    func helpReceivesEofAndSuccessfulHelpIsReusedWithoutChangingActionOutput() async throws {
        let fixture = try ProcessFixture(script: """
            if [ "$1" = '--help' ]; then
              /bin/cat > "$0.help-input"
              printf x >> "$0.help-runs"
              /bin/cat <<'NOOK_HELP'
            \(Self.validHelp)
            NOOK_HELP
              exit 0
            fi
            /bin/cat
            """)
        defer { fixture.remove() }
        let assistant = CommandLineAssistant(executables: [.claude: fixture.executable])
        let note = "  Exact e\u{301} café\n\n"
        for _ in 0..<2 {
            let result = try await assistant.run(.tidy, on: note, using: .claude)
            #expect(result.utf8.elementsEqual(note.utf8))
        }
        #expect(try fixture.data("help-input").isEmpty)
        #expect(try fixture.data("help-runs") == Data("x".utf8))
    }

    @Test
    func cancellingHelpDoesNotStartANoteAction() async throws {
        let fixture = try ProcessFixture(script: """
            if [ "$1" = '--help' ]; then
              trap '' TERM
              printf ready > "$0.ready"
              exec /bin/sleep 30
            fi
            printf ran > "$0.ran"
            """)
        defer { fixture.remove() }
        let assistant = CommandLineAssistant(
            executables: [.claude: fixture.executable],
            helpLimits: CommandLineProcessLimits(stdoutBytes: 1_024, stderrBytes: 1_024, timeout: 3)
        )
        let request = Task { try await assistant.run(.tidy, on: "Private words", using: .claude) }
        try await fixture.waitForMarker("ready")
        request.cancel()
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(!fixture.markerExists("ran"))
    }

    @Test
    func timedOutHelpNeverStartsANoteAction() async throws {
        let fixture = try ProcessFixture(script: """
            if [ "$1" = '--help' ]; then
              trap '' TERM
              exec /bin/sleep 30
            fi
            printf ran > "$0.ran"
            """)
        defer { fixture.remove() }
        let assistant = CommandLineAssistant(
            executables: [.claude: fixture.executable],
            helpLimits: CommandLineProcessLimits(stdoutBytes: 1_024, stderrBytes: 1_024, timeout: 0.15)
        )
        do {
            _ = try await assistant.run(.tidy, on: "Private words", using: .claude)
            Issue.record("Timed out help must refuse the action.")
        } catch NoteAssistantError.unsupportedVersion(let engine) {
            #expect(engine == .claude)
        }
        #expect(!fixture.markerExists("ran"))
    }

    @Test
    func oversizedActionOutputHasAnActionableErrorAndNoPartialResult() async throws {
        let fixture = try ProcessFixture(script: """
            if [ "$1" = '--help' ]; then
              /bin/cat <<'NOOK_HELP'
            \(Self.validHelp)
            NOOK_HELP
              exit 0
            fi
            /bin/cat >/dev/null
            /bin/dd if=/dev/zero bs=16384 count=4 2>/dev/null
            """)
        defer { fixture.remove() }
        let assistant = CommandLineAssistant(
            executables: [.claude: fixture.executable],
            actionLimits: CommandLineProcessLimits(stdoutBytes: 1_024, stderrBytes: 1_024, timeout: 3)
        )
        do {
            _ = try await assistant.run(.tidy, on: "Keep these exact words", using: .claude)
            Issue.record("An oversized response must not become replacement text.")
        } catch NoteAssistantError.failed(let message) {
            #expect(message.contains("too much output"))
            #expect(message.contains("Your note is unchanged"))
        }
    }

    @Test
    func invalidUtf8OutputIsRejectedInsteadOfReplacingBytes() async throws {
        let fixture = try ProcessFixture(script: """
            if [ "$1" = '--help' ]; then
              /bin/cat <<'NOOK_HELP'
            \(Self.validHelp)
            NOOK_HELP
              exit 0
            fi
            /bin/cat >/dev/null
            printf '\\377'
            """)
        defer { fixture.remove() }
        let assistant = CommandLineAssistant(executables: [.claude: fixture.executable])
        do {
            _ = try await assistant.run(.tidy, on: "Keep these exact words", using: .claude)
            Issue.record("Invalid UTF-8 must not become replacement text.")
        } catch NoteAssistantError.failed(let message) {
            #expect(message.contains("unreadable text"))
        }
    }

    @Test
    func aFailedActionShowsOnlyABoundedDiagnostic() async throws {
        let fixture = try ProcessFixture(script: """
            if [ "$1" = '--help' ]; then
              /bin/cat <<'NOOK_HELP'
            \(Self.validHelp)
            NOOK_HELP
              exit 0
            fi
            /bin/cat >/dev/null
            i=0
            while [ "$i" -lt 1000 ]; do printf 'synthetic diagnostic\\n' >&2; i=$((i + 1)); done
            exit 1
            """)
        defer { fixture.remove() }
        let assistant = CommandLineAssistant(executables: [.claude: fixture.executable])
        do {
            _ = try await assistant.run(.tidy, on: "Private words", using: .claude)
            Issue.record("A failed action must not return replacement text.")
        } catch NoteAssistantError.failed(let message) {
            #expect(message.hasPrefix("synthetic diagnostic"))
            #expect(message.utf8.count <= 4_096)
        }
    }
}

private struct ProcessFixture: Sendable {
    let directory: URL
    let executable: URL

    init(script: String) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NookSyntheticCLI-\(UUID().uuidString)", isDirectory: true)
        executable = directory.appendingPathComponent("synthetic-helper")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        try replace(script: script)
    }

    func replace(script: String) throws {
        try Data(("#!/bin/sh\n" + script + "\n").utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }

    func markerExists(_ suffix: String) -> Bool {
        FileManager.default.fileExists(atPath: executable.path + "." + suffix)
    }

    func data(_ suffix: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: executable.path + "." + suffix))
    }

    func pid() throws -> pid_t {
        let contents = String(decoding: try data("pid"), as: UTF8.self)
        return try #require(pid_t(contents))
    }

    func waitForMarker(_ suffix: String) async throws {
        for _ in 0..<200 {
            if markerExists(suffix) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw FixtureError.markerMissing
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
    private enum FixtureError: Error { case markerMissing }
}
