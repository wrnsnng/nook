import Darwin
import Foundation
import Testing
@testable import Nook

@MainActor
struct DraftProcessRecoveryTests {
    private struct Receipt: Decodable { let path: String; let remaining: Int }

    @Test(arguments: DraftEditorKind.allCases, ["unchanged", "external-edit", "unavailable-library"])
    func killedEditorProcessesRecoverExactCheckpointsWithoutOverwritingOriginals(kind: DraftEditorKind, scenario: String) async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("Nook-Recovery-Process-\(UUID())")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        try "synthetic-only".write(to: root.appendingPathComponent("probe.marker"), atomically: true, encoding: .utf8)
        let app = Bundle.main.bundleURL
        let tool = app.deletingLastPathComponent().appendingPathComponent("NookRecoveryProbe")
        try #require(manager.isExecutableFile(atPath: tool.path))
        func child(_ operation: String) throws -> Process {
            let process = Process()
            process.executableURL = tool
            process.arguments = [operation, root.path, kind.rawValue]
            // Tools need the same built frameworks as the app test host.
            var environment = ProcessInfo.processInfo.environment
            environment["DYLD_FRAMEWORK_PATH"] = app.deletingLastPathComponent().path
            process.environment = environment
            let output = root.appendingPathComponent(operation + ".log")
            manager.createFile(atPath: output.path, contents: nil)
            let handle = try FileHandle(forWritingTo: output)
            process.standardOutput = handle
            process.standardError = handle
            try process.run()
            try handle.close()
            return process
        }
        let writer = try child("checkpoint")
        defer { if writer.isRunning { kill(writer.processIdentifier, SIGKILL) } }
        let ready = root.appendingPathComponent("ready.json")
        for _ in 0..<1_000 where !manager.fileExists(atPath: ready.path) && writer.isRunning {
            try await Task.sleep(for: .milliseconds(10))
        }
        let checkpointLog = try String(contentsOf: root.appendingPathComponent("checkpoint.log"), encoding: .utf8)
        try #require(manager.fileExists(atPath: ready.path), "Probe failed before acknowledging its checkpoint: \(checkpointLog)")
        let checkpoint = try JSONDecoder().decode(DraftCheckpoint.self, from: Data(contentsOf: ready))
        #expect(checkpoint.kind == kind)
        #expect(checkpoint.text.contains("Cafe\u{301} 日本語 👩🏽‍💻\r\n"))
        let originalDirectory = root.appendingPathComponent("Library")
        let originals = try manager.contentsOfDirectory(at: originalDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }
        var expected: [String: Data] = [:]
        for file in originals { expected[file.lastPathComponent] = try Data(contentsOf: file) }
        try #require(kill(writer.processIdentifier, SIGKILL) == 0)
        for _ in 0..<1_000 where writer.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        try #require(!writer.isRunning, "Killed checkpoint probe did not terminate")
        #expect(writer.terminationReason == .uncaughtSignal)
        #expect(writer.terminationStatus == SIGKILL)
        var retainedDirectory = originalDirectory
        if scenario == "external-edit", let file = originals.first {
            let edited = try Data(contentsOf: file) + Data("\nExternal writer's newer words.\n".utf8)
            try edited.write(to: file)
            expected[file.lastPathComponent] = edited
        } else if scenario == "unavailable-library" {
            retainedDirectory = root.appendingPathComponent("Unavailable Library")
            try manager.moveItem(at: originalDirectory, to: retainedDirectory)
        }
        let reader = try child("recover")
        defer { if reader.isRunning { kill(reader.processIdentifier, SIGKILL) } }
        for _ in 0..<1_000 where reader.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        try #require(!reader.isRunning, "Recovery probe exceeded its deadline")
        let recoveryLog = try String(contentsOf: root.appendingPathComponent("recover.log"), encoding: .utf8)
        try #require(reader.terminationStatus == 0, "Recovery probe failed: \(recoveryLog)")
        let receipt = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: root.appendingPathComponent("result.json")))
        #expect(receipt.remaining == 0)
        let recoveredBytes = try Data(contentsOf: URL(fileURLWithPath: receipt.path))
        let recoveredSource = try #require(String(data: recoveredBytes, encoding: .utf8))
        let recovered = try #require(MarkdownCodec.decode(recoveredSource))
        #expect(recovered.id != checkpoint.noteID)
        if kind == .markdown {
            let originalID = try #require(checkpoint.noteID)
            let oldIdentity = "id: \(originalID.uuidString)"
            var expectedSource = checkpoint.text
            let range = try #require(expectedSource.range(of: oldIdentity))
            expectedSource.replaceSubrange(range, with: "id: \(recovered.id.uuidString)")
            #expect(recoveredBytes == Data(expectedSource.utf8))
        } else {
            #expect(recoveredBytes.suffix(checkpoint.text.utf8.count).elementsEqual(checkpoint.text.utf8))
        }
        for (name, bytes) in expected {
            #expect(try Data(contentsOf: retainedDirectory.appendingPathComponent(name)) == bytes)
        }
    }
}
