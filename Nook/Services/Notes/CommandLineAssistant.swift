import Darwin
import Foundation
import Synchronization

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
/// line. No shell parses the note text. The provider's agent capabilities need
/// separate restrictions, checked before handing it the note.
actor CommandLineAssistant {
    private let actionLimits: CommandLineProcessLimits
    private let helpLimits: CommandLineProcessLimits

    private var located: [NoteAssistantEngine: URL] = [:]
    private var searched: Set<NoteAssistantEngine> = []
    /// Each tool's help text, read once and kept for the life of the app run.
    private var helpTexts: [NoteAssistantEngine: String] = [:]

    /// Overrides let tests exercise the real pipe and cancellation path using
    /// synthetic executables, without discovering or invoking a provider.
    init(
        executables: [NoteAssistantEngine: URL] = [:],
        actionLimits: CommandLineProcessLimits = .action,
        helpLimits: CommandLineProcessLimits = .help
    ) {
        located = executables
        self.actionLimits = actionLimits
        self.helpLimits = helpLimits
    }

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
        try Task.checkCancellation()
        guard let executable = locate(engine) else {
            throw NoteAssistantError.unavailable(engine)
        }

        guard engine != .onDevice else {
            throw NoteAssistantError.unavailable(engine)
        }

        let arguments = try Self.arguments(
            for: engine,
            instruction: action.instruction,
            supportedFlagsIn: try await help(for: engine, at: executable)
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
    /// folder. Every run therefore requires the provider's restrictions on
    /// tools, configuration, and session persistence. Codex's read-only sandbox
    /// does not disable file reads, so these flags are not an independent
    /// guarantee that the tool can see only the note passed on standard input.
    ///
    /// Compatibility must not weaken that boundary. Missing or unreadable
    /// help refuses the run before the note is handed to a process; filtering
    /// out unsupported flags silently restored the installed agent's powers.
    ///
    /// Pure, so the shape of the command line can be asserted in a test.
    static func arguments(
        for engine: NoteAssistantEngine,
        instruction: String,
        supportedFlagsIn helpText: String?
    ) throws -> [String] {
        let requiredFlags: [String]
        switch engine {
        case .claude:
            requiredFlags = [
                "--safe-mode", "--tools", "--strict-mcp-config",
                "--permission-mode", "--no-session-persistence"
            ]
        case .codex:
            requiredFlags = [
                "--skip-git-repo-check", "--sandbox", "--ignore-user-config",
                "--ignore-rules", "--ephemeral"
            ]
        case .onDevice:
            return []
        }
        guard let helpText,
              requiredFlags.allSatisfy({ advertises($0, in: helpText) }) else {
            throw NoteAssistantError.unsupportedVersion(engine)
        }
        switch engine {
        case .claude:
            // The tool list is variadic. A flag between it and the prompt
            // prevents the instruction from being read as another tool name.
            return [
                "--safe-mode", "--tools", "", "--strict-mcp-config",
                "--permission-mode", "manual", "--no-session-persistence",
                "-p", instruction
            ]
        case .codex:
            // Ignoring configuration is separate from the sandbox:
            // filesystem restrictions do not cover configured MCP servers.
            return [
                "exec", "--skip-git-repo-check", "--sandbox", "read-only",
                "--ignore-user-config", "--ignore-rules", "--ephemeral",
                instruction
            ]
        case .onDevice:
            return []
        }
    }

    /// Only an option declaration counts. A description mentioning a flag,
    /// or a longer option such as `--tools-extra`, proves no support for it.
    private static func advertises(_ flag: String, in helpText: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: flag)
        let pattern = #"(?m)^[\t ]*(?:-[A-Za-z0-9],[\t ]*)?"#
            + escaped + #"(?=[\t =,]|$)"#
        return helpText.range(of: pattern, options: .regularExpression) != nil
    }

    /// The tool's own help text, read once per engine.
    ///
    /// Reading it costs one process launch per app run and answers a question
    /// that cannot be answered any other way: which of these flags this
    /// particular installed version understands.
    private func help(
        for engine: NoteAssistantEngine,
        at executable: URL
    ) async throws -> String? {
        try Task.checkCancellation()
        if let cached = helpTexts[engine] { return cached }
        let arguments: [String] = switch engine {
        case .claude: ["--help"]
        case .codex: ["exec", "--help"]
        case .onDevice: []
        }
        guard !arguments.isEmpty else { return nil }
        do {
            // An empty input closes stdin immediately. Help must never inherit
            // input from the app, and it is subject to the same bounded pump.
            let result = try await CommandLineProcessRunner.run(
                executable: executable, arguments: arguments, input: Data(),
                environment: Self.environment, limits: helpLimits
            )
            guard result.exitStatus == 0,
                  let text = String(data: result.stdout, encoding: .utf8),
                  !text.isEmpty else { return nil }
            helpTexts[engine] = text
            return text
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // A failed, oversized or incomplete help response establishes no
            // support for the required restrictions. Never run with fewer.
            return nil
        }
    }

    private func execute(
        executable: URL,
        arguments: [String],
        input: String,
        engine: NoteAssistantEngine
    ) async throws -> String {
        let result: CommandLineProcessResult
        do {
            result = try await CommandLineProcessRunner.run(
                executable: executable, arguments: arguments, input: Data(input.utf8),
                environment: Self.environment, limits: actionLimits
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch CommandLineProcessError.launchFailed {
            throw NoteAssistantError.unavailable(engine)
        } catch CommandLineProcessError.timedOut {
            throw NoteAssistantError.failed(
                "\(engine.title) took too long and was stopped. Your note is unchanged."
            )
        } catch CommandLineProcessError.outputLimit {
            throw NoteAssistantError.failed(
                "\(engine.title) returned too much output and was stopped. Your note is unchanged."
            )
        } catch {
            throw NoteAssistantError.failed(
                "\(engine.title) could not finish exchanging the note. Your note is unchanged."
            )
        }
        guard result.exitStatus == 0 else {
            // Provider diagnostics can contain note text. Keep them transient
            // and small; neither output stream is written to an app log.
            let message = String(decoding: result.stderr.prefix(4_096), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw NoteAssistantError.failed(
                message.isEmpty
                    ? "\(engine.title) could not complete that. Check that it is signed in."
                    : message
            )
        }
        guard let text = String(data: result.stdout, encoding: .utf8) else {
            throw NoteAssistantError.failed(
                "\(engine.title) returned unreadable text. Your note is unchanged."
            )
        }
        return text
    }

    /// Construct, rather than filter, the environment. Reading the app's
    /// environment would also read credentials and runtime injection options
    /// that have no reason to cross this bridge. The CLI still locates its own
    /// authentication through the account's real home directory.
    static var environment: [String: String] {
        [
            "HOME": NSHomeDirectory(),
            "USER": NSUserName(),
            "LOGNAME": NSUserName(),
            "PATH": searchPath,
            "TMPDIR": NSTemporaryDirectory(),
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8"
        ]
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

struct CommandLineProcessLimits: Sendable {
    let stdoutBytes: Int
    let stderrBytes: Int
    let timeout: TimeInterval
    var terminationGrace: TimeInterval = 0.3

    static let action = Self(stdoutBytes: 2 * 1_024 * 1_024, stderrBytes: 64 * 1_024, timeout: 90)
    static let help = Self(stdoutBytes: 256 * 1_024, stderrBytes: 64 * 1_024, timeout: 10)
}

struct CommandLineProcessResult: Sendable {
    let stdout: Data
    let stderr: Data
    let exitStatus: Int32
}

enum CommandLineProcessError: Error, Equatable {
    case launchFailed
    case timedOut
    case outputLimit
    case incompleteInput
    case incompleteOutput
    case ioFailure
}

/// One nonblocking pump owns each child's descriptors and lifecycle. Blocking
/// FileHandle reads cannot be cancelled when a descendant keeps a pipe open;
/// a separate writer can also block forever when the child ignores stdin.
/// Polling all three pipes off the cooperative pool bounds both cases, and a
/// finite read per turn stops an output flood from starving cancellation.
enum CommandLineProcessRunner {
    static func run(
        executable: URL,
        arguments: [String],
        input: Data,
        environment: [String: String],
        limits: CommandLineProcessLimits
    ) async throws -> CommandLineProcessResult {
        try Task.checkCancellation()
        let cancellation = ProcessCancellation()
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<CommandLineProcessResult, any Error>) in
                let operation: @Sendable () -> Void = {
                    continuation.resume(with: Result {
                        try pump(
                            executable: executable, arguments: arguments, input: input,
                            environment: environment, limits: limits,
                            isCancelled: { cancellation.isCancelled }
                        )
                    })
                }
                DispatchQueue.global(qos: .userInitiated).async(execute: operation)
            }
        } onCancel: {
            cancellation.cancel()
        }
        try Task.checkCancellation()
        return result
    }

    private static func pump(
        executable: URL,
        arguments: [String],
        input: Data,
        environment: [String: String],
        limits: CommandLineProcessLimits,
        isCancelled: @Sendable () -> Bool
    ) throws -> CommandLineProcessResult {
        guard limits.stdoutBytes >= 0, limits.stderrBytes >= 0,
              limits.timeout.isFinite, limits.timeout > 0,
              limits.terminationGrace.isFinite, limits.terminationGrace >= 0 else {
            throw CommandLineProcessError.launchFailed
        }
        if isCancelled() { throw CancellationError() }
        let started = monotonicTime
        let stdin = try ProcessPipe()
        let stdout = try ProcessPipe()
        let stderr = try ProcessPipe()
        let pid = try spawn(
            executable: executable, arguments: arguments, environment: environment,
            stdin: stdin, stdout: stdout, stderr: stderr
        )
        stdin.closeRead()
        stdout.closeWrite()
        stderr.closeWrite()

        var ownsLeader = true
        // Keep the leader waitable until every group signal is finished. If it
        // were reaped first, its PID could be reused by an unrelated process.
        defer {
            stdin.closeWrite()
            stdout.closeRead()
            stderr.closeRead()
            if ownsLeader {
                _ = kill(-pid, SIGKILL)
                reap(pid)
            }
        }
        try stdin.configureParentWrite()
        try stdout.configureParentRead()
        try stderr.configureParentRead()
        var output = Data()
        var errors = Data()
        var inputOffset = 0
        var exitStatus: Int32?
        var exitObservedAt: TimeInterval?
        var stopReason: (any Error)?
        var stoppedAt: TimeInterval?
        if input.isEmpty { stdin.closeWrite() }

        func stop(_ error: any Error, at now: TimeInterval) {
            guard stopReason == nil else { return }
            stopReason = error
            stoppedAt = now
            stdin.closeWrite()
            _ = kill(-pid, SIGTERM)
        }

        while true {
            let now = monotonicTime
            if isCancelled() {
                stop(CancellationError(), at: now)
            } else if now - started >= limits.timeout {
                stop(CommandLineProcessError.timedOut, at: now)
            }

            if exitStatus == nil {
                var info = siginfo_t()
                let status = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
                if status == 0, info.si_pid == pid {
                    exitStatus = info.si_code == CLD_EXITED ? info.si_status : 128 + info.si_status
                    exitObservedAt = now
                    if inputOffset < input.count {
                        stop(CommandLineProcessError.incompleteInput, at: now)
                    }
                } else if status != 0, errno != EINTR {
                    // No signal after ownership was lost, even if another
                    // subsystem unexpectedly reaped our child.
                    ownsLeader = errno != ECHILD
                    throw CommandLineProcessError.ioFailure
                }
            }
            if exitStatus != nil, stdout.readFD < 0, stderr.readFD < 0 { break }
            if let stoppedAt, now - stoppedAt >= limits.terminationGrace { break }
            // A successful leader cannot leave a helper holding the caller
            // open until the full action deadline. Allow buffered output to
            // drain, then refuse an incomplete response and stop the group.
            if let exitObservedAt, now - exitObservedAt >= 0.25 {
                stop(CommandLineProcessError.incompleteOutput, at: now)
            }

            var descriptors = [
                pollfd(fd: stdout.readFD, events: Int16(POLLIN), revents: 0),
                pollfd(fd: stderr.readFD, events: Int16(POLLIN), revents: 0),
                pollfd(fd: stdin.writeFD, events: Int16(POLLOUT), revents: 0)
            ]
            let ready = poll(&descriptors, nfds_t(descriptors.count), 20)
            if ready < 0 {
                if errno != EINTR { stop(CommandLineProcessError.ioFailure, at: monotonicTime) }
                continue
            }
            do {
                if descriptors[0].revents != 0 {
                    try read(stdout, into: &output, limit: limits.stdoutBytes)
                }
                if descriptors[1].revents != 0 {
                    try read(stderr, into: &errors, limit: limits.stderrBytes)
                }
                if stdin.writeFD >= 0, descriptors[2].revents != 0 {
                    let written = input.withUnsafeBytes { bytes in
                        Darwin.write(
                            stdin.writeFD, bytes.baseAddress!.advanced(by: inputOffset),
                            min(16_384, input.count - inputOffset)
                        )
                    }
                    if written > 0 {
                        inputOffset += written
                        if inputOffset == input.count { stdin.closeWrite() }
                    } else if written < 0, errno != EAGAIN, errno != EINTR {
                        throw CommandLineProcessError.incompleteInput
                    }
                }
            } catch {
                stop(error, at: monotonicTime)
            }
        }
        if let stopReason { throw stopReason }
        guard let exitStatus else { throw CommandLineProcessError.ioFailure }
        return CommandLineProcessResult(stdout: output, stderr: errors, exitStatus: exitStatus)
    }

    private static func read(_ pipe: ProcessPipe, into data: inout Data, limit: Int) throws {
        var buffer = [UInt8](repeating: 0, count: 16_384)
        // Read at most one extra byte to detect overflow, but never append it.
        let count = Darwin.read(pipe.readFD, &buffer, min(buffer.count - 1, limit - data.count) + 1)
        if count == 0 {
            pipe.closeRead()
        } else if count > 0 {
            guard count <= limit - data.count else { throw CommandLineProcessError.outputLimit }
            data.append(contentsOf: buffer.prefix(count))
        } else if errno != EAGAIN, errno != EINTR {
            throw CommandLineProcessError.ioFailure
        }
    }

    private static func spawn(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        stdin: ProcessPipe,
        stdout: ProcessPipe,
        stderr: ProcessPipe
    ) throws -> pid_t {
        let argumentStrings = [executable.path] + arguments
        let environmentStrings = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        guard (argumentStrings + environmentStrings).allSatisfy({ !$0.utf8.contains(0) }),
              environment.keys.allSatisfy({ !$0.isEmpty && !$0.contains("=") }) else {
            throw CommandLineProcessError.launchFailed
        }
        var actions: posix_spawn_file_actions_t?
        try check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        var attributes: posix_spawnattr_t?
        try check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }

        try check(posix_spawn_file_actions_adddup2(&actions, stdin.readFD, STDIN_FILENO))
        try check(posix_spawn_file_actions_adddup2(&actions, stdout.writeFD, STDOUT_FILENO))
        try check(posix_spawn_file_actions_adddup2(&actions, stderr.writeFD, STDERR_FILENO))
        try check(posix_spawn_file_actions_addchdir(&actions, NSTemporaryDirectory()))
        // Creating the group inside posix_spawn avoids a setpgid race after
        // exec. It is cleanup ownership, not a sandbox: a hostile tool can
        // deliberately escape a process group or perform other allowed work.
        try check(posix_spawnattr_setpgroup(&attributes, 0))
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for signal in [SIGPIPE, SIGTERM, SIGINT, SIGHUP] { sigaddset(&defaults, signal) }
        try check(posix_spawnattr_setsigdefault(&attributes, &defaults))
        var mask = sigset_t()
        sigemptyset(&mask)
        try check(posix_spawnattr_setsigmask(&attributes, &mask))
        try check(posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
                  | POSIX_SPAWN_CLOEXEC_DEFAULT)
        ))

        let argv = try cStrings(argumentStrings)
        defer { argv.forEach { free($0) } }
        let envp = try cStrings(environmentStrings)
        defer { envp.forEach { free($0) } }
        var pid: pid_t = 0
        let status = argv.withUnsafeBufferPointer { argvBuffer in
            envp.withUnsafeBufferPointer { environmentBuffer in
                posix_spawn(
                    &pid, executable.path, &actions, &attributes,
                    argvBuffer.baseAddress!, environmentBuffer.baseAddress!
                )
            }
        }
        try check(status)
        return pid
    }

    private static func check(_ status: Int32) throws {
        guard status == 0 else { throw CommandLineProcessError.launchFailed }
    }

    private static func cStrings(_ strings: [String]) throws -> [UnsafeMutablePointer<CChar>?] {
        var pointers: [UnsafeMutablePointer<CChar>?] = []
        for string in strings {
            guard let pointer = strdup(string) else {
                pointers.forEach { free($0) }
                throw CommandLineProcessError.launchFailed
            }
            pointers.append(pointer)
        }
        pointers.append(nil)
        return pointers
    }

    private static var monotonicTime: TimeInterval {
        TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    private static func reap(_ pid: pid_t) {
        var status: Int32 = 0
        let deadline = monotonicTime + 0.5
        repeat {
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid || (result < 0 && errno == ECHILD) { return }
            usleep(1_000)
        } while monotonicTime < deadline
        // SIGKILL normally makes reaping immediate. Kernel-level stalls must
        // not extend the UI deadline; only waiting, never signalling a reused
        // PID, may outlive this request. All pipe ends are already closed.
        let wait: @Sendable () -> Void = {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        }
        DispatchQueue.global(qos: .utility).async(execute: wait)
    }
}

private final class ProcessCancellation: Sendable {
    private let value = Mutex(false)

    var isCancelled: Bool { value.withLock { $0 } }
    func cancel() { value.withLock { $0 = true } }
}

/// Used only on the pump's queue. Nonblocking flags apply to the parent's
/// ends; children receive ordinary blocking stdin/stdout/stderr. CLOEXEC and
/// spawn's close-by-default prevent unrelated descriptors entering a tool.
private final class ProcessPipe {
    private(set) var readFD: Int32 = -1
    private(set) var writeFD: Int32 = -1

    init() throws {
        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else { throw CommandLineProcessError.launchFailed }
        readFD = descriptors[0]
        writeFD = descriptors[1]
        do {
            readFD = try Self.prepare(readFD)
            writeFD = try Self.prepare(writeFD)
        } catch {
            closeRead()
            closeWrite()
            throw error
        }
    }

    private static func prepare(_ descriptor: Int32) throws -> Int32 {
        // Keep pipe sources clear of dup2's standard-descriptor destinations,
        // even when Nook happened to launch with a standard descriptor closed.
        let result = fcntl(descriptor, F_DUPFD_CLOEXEC, 3)
        guard result >= 0 else { throw CommandLineProcessError.launchFailed }
        close(descriptor)
        return result
    }

    func closeRead() {
        if readFD >= 0 { close(readFD); readFD = -1 }
    }

    func closeWrite() {
        if writeFD >= 0 { close(writeFD); writeFD = -1 }
    }

    func configureParentRead() throws {
        guard fcntl(readFD, F_SETFL, O_NONBLOCK) != -1 else {
            throw CommandLineProcessError.ioFailure
        }
    }

    func configureParentWrite() throws {
        guard fcntl(writeFD, F_SETFL, O_NONBLOCK) != -1,
              fcntl(writeFD, F_SETNOSIGPIPE, 1) != -1 else {
            throw CommandLineProcessError.ioFailure
        }
    }

    deinit { closeRead(); closeWrite() }
}
