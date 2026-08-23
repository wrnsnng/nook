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
    /// Each tool's help text, read once and kept for the life of the app run.
    private var helpTexts: [NoteAssistantEngine: String] = [:]

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

        guard engine != .onDevice else {
            throw NoteAssistantError.unavailable(engine)
        }

        let arguments = Self.arguments(
            for: engine,
            instruction: action.instruction,
            supportedFlagsIn: await help(for: engine, at: executable)
        )

        return try await execute(
            executable: executable,
            arguments: arguments,
            input: note,
            engine: engine
        )
    }

    /// Builds the command line for one run.
    ///
    /// Both tools are agents by default: they read files, run commands, and
    /// call whatever MCP servers and hooks the user has configured, under the
    /// permissions that user already granted for their own work. A note is
    /// dictated speech and other people's writing, and it routinely reads as
    /// instructions. Sending it to a tool that can act would turn "remind me to
    /// clear the downloads folder" into something that clears the downloads
    /// folder. These runs are therefore stripped down to what a rewrite needs:
    /// no tools, no MCP servers, no user customisation, and no session file
    /// left behind holding the note.
    ///
    /// The flags are filtered against the tool's own help text rather than
    /// assumed, because an unrecognised flag is a hard exit on both tools and
    /// Nook does not control which version is installed. `helpText` is nil when
    /// the help could not be read, and the full set is used then: a run that
    /// fails loudly is better than one that quietly runs unrestricted.
    ///
    /// Pure, so the shape of the command line can be asserted in a test.
    static func arguments(
        for engine: NoteAssistantEngine,
        instruction: String,
        supportedFlagsIn helpText: String?
    ) -> [String] {
        func supported(_ flag: String) -> Bool {
            guard let helpText else { return true }
            return helpText.contains(flag)
        }

        switch engine {
        case .claude:
            var arguments: [String] = []
            if supported("--safe-mode") {
                // No CLAUDE.md, skills, plugins, hooks, custom agents, or MCP
                // servers. Authentication is untouched, which is the whole
                // point of the bridge.
                arguments.append("--safe-mode")
            }
            if supported("--tools") {
                // The documented way to disable every built-in tool.
                arguments.append(contentsOf: ["--tools", ""])
            }
            if supported("--strict-mcp-config") {
                // With no --mcp-config alongside it, this means no MCP server
                // at all, including any the user configured globally.
                arguments.append("--strict-mcp-config")
            }
            if supported("--permission-mode") {
                // Nothing runs without an approval, and a print-mode run has
                // nobody there to give one.
                arguments.append(contentsOf: ["--permission-mode", "manual"])
            }
            if supported("--no-session-persistence") {
                // The note is not left in a transcript on disk afterwards.
                arguments.append("--no-session-persistence")
            }
            // `-p` is last on purpose. `--tools` takes a list, so it would
            // swallow the instruction as another tool name if the instruction
            // followed it directly; a flag in between ends the list. `-p` is
            // the one flag this bridge cannot work without, so it is always
            // there to do that job.
            arguments.append(contentsOf: ["-p", instruction])
            return arguments
        case .codex:
            var arguments = ["exec", "--skip-git-repo-check"]
            if supported("--sandbox") {
                // Codex has no way to switch its tools off, so the sandbox is
                // the limit: commands it runs cannot write or reach the network.
                arguments.append(contentsOf: ["--sandbox", "read-only"])
            }
            if supported("--ignore-user-config") {
                // Where the user's MCP servers are configured, which the
                // sandbox does not cover. Authentication is unaffected.
                arguments.append("--ignore-user-config")
            }
            if supported("--ignore-rules") {
                arguments.append("--ignore-rules")
            }
            if supported("--ephemeral") {
                // No session file holding the note afterwards.
                arguments.append("--ephemeral")
            }
            arguments.append(instruction)
            return arguments
        case .onDevice:
            return []
        }
    }

    /// The tool's own help text, read once per engine.
    ///
    /// Reading it costs one process launch per app run and answers a question
    /// that cannot be answered any other way: which of these flags this
    /// particular installed version understands.
    private func help(
        for engine: NoteAssistantEngine,
        at executable: URL
    ) async -> String? {
        if let cached = helpTexts[engine] { return cached }
        let arguments: [String] = switch engine {
        case .claude: ["--help"]
        case .codex: ["exec", "--help"]
        case .onDevice: []
        }
        let text = await Self.readHelp(
            executable: executable,
            arguments: arguments
        )
        if let text {
            helpTexts[engine] = text
        }
        return text
    }

    /// Runs `<tool> --help` and returns what it printed.
    ///
    /// Deliberately not routed through `execute`: nothing is written to this
    /// process's standard input, there is no note involved, and a tool that
    /// cannot print its own help within a few seconds is not one to wait on.
    private static func readHelp(
        executable: URL,
        arguments: [String]
    ) async -> String? {
        guard !arguments.isEmpty else { return nil }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = Self.searchPath
        process.environment = environment
        process.currentDirectoryURL = URL(
            fileURLWithPath: NSTemporaryDirectory()
        )

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            return nil
        }

        let handle = ProcessHandle(process: process)
        let timeout = Task {
            try? await Task.sleep(for: Self.helpTimeout)
            guard !Task.isCancelled else { return }
            await handle.terminate()
        }
        // Both pipes again, for the reason `execute` drains both: a tool that
        // fills the one nobody is reading never reaches the one that is.
        async let errors = Self.readAll(stderr.fileHandleForReading)
        let data = await Self.readAll(stdout.fileHandleForReading)
        _ = await errors
        await Self.waitForExit(handle)
        timeout.cancel()

        let text = String(decoding: data, as: UTF8.self)
        return text.isEmpty ? nil : text
    }

    private static let helpTimeout: Duration = .seconds(10)

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

        // The note is written after the readers and the deadline below exist,
        // and off this actor.
        //
        // A pipe holds about 64KB. A note larger than that fills it, and the
        // write then waits for the child to read, which a child busy printing
        // to a pipe nobody is draining yet will never do. Writing here
        // synchronously blocked one of the cooperative pool's threads for as
        // long as that took, which is unrelated work across the whole app, and
        // put the write in front of the only thing that could break the
        // deadlock.
        //
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

        async let written: Void = Self.writeAll(
            Data(input.utf8),
            to: stdin.fileHandleForWriting
        )
        async let output = Self.readAll(stdout.fileHandleForReading)
        async let errors = Self.readAll(stderr.fileHandleForReading)
        let outputData = await output
        let errorData = await errors
        // Returns once the child has read the note, or immediately once the
        // child is gone and the pipe is broken. Awaited after the reads so a
        // child that never reads its input cannot hold this up.
        await written
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

    /// Writes a pipe to the end without blocking the actor, then closes it.
    ///
    /// `write(contentsOf:)` rather than `write(_:)`: the child may have exited
    /// already, and the older call raises an Objective-C exception on a broken
    /// pipe, which Swift cannot catch and which would take the app down.
    private static func writeAll(_ data: Data, to handle: FileHandle) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                try? handle.write(contentsOf: data)
                try? handle.close()
                continuation.resume()
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
