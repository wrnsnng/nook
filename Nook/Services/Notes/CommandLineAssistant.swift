import Foundation

/// Runs a note action through a command-line tool the user has already signed
/// into.
///
/// This is how Nook reaches a Claude or Codex subscription without asking for a
/// second one, and without handling anyone's credentials. Both tools expose a
/// documented non-interactive mode and manage their own authentication, so Nook
/// never reads a token, never stores one, and never has one to leak. Reusing
/// the OAuth credential those tools hold would work too, and is deliberately not
/// done: that credential is issued to them, and presenting another app's traffic
/// as theirs puts the user's account at risk rather than Nook's.
///
/// Note text is passed on standard input, never interpolated into a command
/// line. No shell is involved at any point, so nothing in a note can be read as
/// a command.
actor CommandLineAssistant {
    /// A rewrite is interactive. Past this the user is better served by an
    /// error than by a spinner.
    private static let timeout: Duration = .seconds(90)

    private var located: [NoteAssistantEngine: URL] = [:]
    private var searched: Set<NoteAssistantEngine> = []

    func locate(_ engine: NoteAssistantEngine) -> URL? {
        if let found = located[engine] { return found }
        guard !searched.contains(engine) else { return nil }
        searched.insert(engine)

        guard let name = executableName(for: engine) else { return nil }
        for candidate in candidatePaths(for: name) {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: candidate.path,
                isDirectory: &isDirectory
            ), !isDirectory.boolValue,
                FileManager.default.isExecutableFile(atPath: candidate.path)
            else {
                continue
            }
            located[engine] = candidate
            return candidate
        }
        return nil
    }

    func run(
        _ action: NoteAction,
        on note: String,
        using engine: NoteAssistantEngine
    ) async throws -> String {
        guard let executable = locate(engine) else {
            throw NoteAssistantError.unavailable(engine)
        }

        let arguments: [String]
        switch engine {
        case .claude:
            // Headless print mode. The note arrives on stdin as material.
            arguments = ["-p", action.instruction]
        case .codex:
            arguments = ["exec", "--skip-git-repo-check", action.instruction]
        case .onDevice:
            throw NoteAssistantError.unavailable(engine)
        }

        return try await execute(
            executable: executable,
            arguments: arguments,
            input: note,
            engine: engine
        )
    }

    private func execute(
        executable: URL,
        arguments: [String],
        input: String,
        engine: NoteAssistantEngine
    ) async throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        // A GUI app inherits almost no PATH, and these tools shell out to node
        // and to their own helpers.
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = Self.searchPath
        process.environment = environment
        // Somewhere harmless to run: these tools take the working directory as
        // their context, and the user's notes folder is not it.
        process.currentDirectoryURL = URL(
            fileURLWithPath: NSTemporaryDirectory()
        )

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw NoteAssistantError.unavailable(engine)
        }

        stdin.fileHandleForWriting.write(Data(input.utf8))
        try? stdin.fileHandleForWriting.close()

        // Both pipes are drained at once, and the deadline runs alongside them.
        //
        // Reading one pipe to the end and then the other cannot work here.
        // `readToEnd` returns only when the child closes that pipe, which for a
        // healthy process means at exit, so a deadline placed after the reads
        // could only ever be checked against an already-finished process. It
        // also deadlocks whenever the child fills the pipe nobody is reading
        // yet, which either of these tools can do by reporting progress on
        // stderr while its result is still on stdout.
        let timedOut = TimeoutFlag()
        let handle = ProcessHandle(process: process)
        let timeout = Task {
            try? await Task.sleep(for: Self.timeout)
            guard !Task.isCancelled else { return }
            timedOut.set()
            // Terminating closes the pipes, which is what releases the reads.
            await handle.terminate()
        }

        async let output = Self.readAll(stdout.fileHandleForReading)
        async let errors = Self.readAll(stderr.fileHandleForReading)
        let outputData = await output
        let errorData = await errors
        await Self.waitForExit(handle)
        timeout.cancel()

        guard !timedOut.isSet else {
            throw NoteAssistantError.failed(
                "\(engine.title) took too long and was stopped. Your note is unchanged."
            )
        }

        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw NoteAssistantError.failed(
                message.isEmpty
                    ? "\(engine.title) could not complete that. Check that it is signed in."
                    : message
            )
        }
        return String(decoding: outputData, as: UTF8.self)
    }

    /// Reads a pipe to the end without blocking the actor.
    ///
    /// `readToEnd` is synchronous and waits on the child, so it is kept off the
    /// cooperative pool: blocking one of those threads starves unrelated work
    /// across the whole app.
    private static func readAll(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let data = (try? handle.readToEnd()) ?? Data()
                continuation.resume(returning: data)
            }
        }
    }

    private static func waitForExit(_ handle: ProcessHandle) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                handle.waitUntilExit()
                continuation.resume()
            }
        }
    }

    private func executableName(for engine: NoteAssistantEngine) -> String? {
        switch engine {
        case .claude: "claude"
        case .codex: "codex"
        case .onDevice: nil
        }
    }

    private func candidatePaths(for name: String) -> [URL] {
        Self.searchDirectories.map {
            URL(fileURLWithPath: $0).appendingPathComponent(name)
        }
    }

    /// Where these tools actually end up. A GUI app launched by Finder gets a
    /// near-empty PATH, so every plausible install location has to be named:
    /// npm, homebrew, bun, volta, and the tools' own installers all differ, and
    /// which one a user has is not knowable in advance.
    private static let searchDirectories: [String] = {
        let home = NSHomeDirectory()
        return [
            "\(home)/.claude/local",
            "\(home)/.local/bin",
            "\(home)/.npm-global/bin",
            "\(home)/.bun/bin",
            "\(home)/.volta/bin",
            "\(home)/.nvm/versions/node/current/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin"
        ]
    }()

    private static let searchPath = (
        searchDirectories + ["/usr/sbin", "/sbin"]
    ).joined(separator: ":")
}

/// Carries a `Process` across the isolation boundaries this needs.
///
/// `Process` is not `Sendable`. What crosses here is limited to reading
/// `isRunning` and `processIdentifier`, and calling `terminate` and
/// `waitUntilExit`, all of which are safe to call from another thread.
private final class ProcessHandle: @unchecked Sendable {
    private let process: Process

    init(process: Process) {
        self.process = process
    }

    /// Asks the process to stop, then insists.
    ///
    /// `terminate()` sends SIGTERM, which a process is free to ignore or be too
    /// stuck to handle. If that happens the pipes never reach end of file and
    /// the read never returns, so the note would sit under a spinner with no
    /// way back. The escalation bounds that.
    func terminate() async {
        guard process.isRunning else { return }
        process.terminate()

        try? await Task.sleep(for: .seconds(3))
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        kill(pid, SIGKILL)
    }

    func waitUntilExit() {
        process.waitUntilExit()
    }
}

/// One-way flag shared between the deadline and the reader.
private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
