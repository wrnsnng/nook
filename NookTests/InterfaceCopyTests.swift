import AppKit
import Foundation
import Testing

/// Guards Nook's copy rules against the thing that always happens otherwise:
/// one slips back in six months from now, in a string nobody reads twice.
struct InterfaceCopyTests {
    /// Files that legitimately contain an em-dash in a string.
    ///
    /// These are not copy. They match text produced by other software: Firefox
    /// and Google Meet put em-dashes in their window titles, and older Nook
    /// releases generated timestamp titles containing one. Changing them would
    /// break detection and misclassify existing notes.
    private static let allowedFiles: Set<String> = [
        "MeetingDetector.swift",
        "SummaryService.swift"
    ]

    @Test
    func noUserFacingStringContainsAnEmDash() throws {
        var offenders: [String] = []

        let files = try swiftFiles()
        // A scan that silently finds zero files (a moved source root, a
        // broken path derived from #filePath) reports no offenders and
        // passes for the wrong reason. Floor it well below the real count so
        // the check fails loudly instead of vacuously.
        #expect(
            files.count > 20,
            "Only found \(files.count) Swift files to scan; the source root is probably wrong."
        )

        for file in files {
            let name = file.lastPathComponent
            guard !Self.allowedFiles.contains(name) else { continue }

            let contents = try String(contentsOf: file, encoding: .utf8)
            let lines = contents.split(
                separator: "\n",
                omittingEmptySubsequences: false
            )
            for lineNumber in emDashLineNumbers(in: contents) {
                let text = lines[lineNumber - 1].trimmingCharacters(
                    in: .whitespaces
                )
                // Diagnostics are not shown to anyone in a release build.
                guard !text.contains("NookDebugLog") else { continue }
                offenders.append("\(name):\(lineNumber): \(text)")
            }
        }

        #expect(
            offenders.isEmpty,
            """
            Em-dashes are not allowed in Nook's interface copy. Use a comma, a \
            colon, or two sentences instead.

            \(offenders.joined(separator: "\n"))
            """
        )
    }

    /// The permission usage strings shown in macOS's system prompts are not
    /// Swift source. They are authored directly as `project.yml` Info.plist
    /// properties, so the Swift scan above never sees them.
    @Test
    func noPermissionUsageDescriptionContainsAnEmDash() throws {
        let contents = try String(contentsOf: try projectYML(), encoding: .utf8)
        var offenders: [String] = []

        for (index, line) in contents.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("NS"), trimmed.contains("UsageDescription:")
            else { continue }
            guard trimmed.contains("—") else { continue }
            offenders.append("project.yml:\(index + 1): \(trimmed)")
        }

        #expect(
            offenders.isEmpty,
            """
            Em-dashes are not allowed in Nook's interface copy, including the \
            permission prompts declared in project.yml. Use a comma, a colon, \
            or two sentences instead.

            \(offenders.joined(separator: "\n"))
            """
        )
    }

    /// Every SF Symbol the interface asks for has to actually exist.
    ///
    /// A misremembered name is not a build error and not a crash: SwiftUI
    /// draws nothing at all. Four had already reached the app this way,
    /// including the header art of an entire onboarding step and the seal in
    /// the update settings, and each one only shows up if somebody happens to
    /// look at that exact screen.
    @Test
    func everySFSymbolNameInTheInterfaceResolves() throws {
        var offenders: [String] = []

        let files = try swiftFiles()
        #expect(
            files.count > 20,
            "Only found \(files.count) Swift files to scan; the source root is probably wrong."
        )

        for file in files {
            let contents = try String(contentsOf: file, encoding: .utf8)
            for (lineNumber, name) in symbolNames(in: contents)
            where NSImage(
                systemSymbolName: name,
                accessibilityDescription: nil
            ) == nil {
                offenders.append(
                    "\(file.lastPathComponent):\(lineNumber): \(name)"
                )
            }
        }

        #expect(
            offenders.isEmpty,
            """
            These SF Symbol names do not resolve on this system, so the \
            controls using them draw no icon at all.

            \(offenders.joined(separator: "\n"))
            """
        )
    }

    /// Symbol names passed to the arguments that actually render one, so an
    /// ordinary dotted string such as a bundle identifier is not mistaken for
    /// an icon.
    private func symbolNames(in contents: String) -> [(Int, String)] {
        let labels = ["systemName", "systemImage", "symbol"]
        var found: [(Int, String)] = []

        for (index, line) in contents.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).enumerated() {
            for label in labels {
                var rest = Substring(line)
                while let marker = rest.range(of: "\(label): \"") {
                    rest = rest[marker.upperBound...]
                    guard let close = rest.firstIndex(of: "\"") else { break }
                    let name = String(rest[..<close])
                    rest = rest[close...]
                    // Skip interpolated names; they are not literals to check.
                    guard !name.contains("\\") else { continue }
                    found.append((index + 1, name))
                }
            }
        }
        return found
    }

    /// Line numbers whose string copy contains an em-dash.
    ///
    /// Scans the file as one stream instead of line by line: a multi-line
    /// string literal keeps its string context across physical lines, which
    /// the previous per-line scan lost, and that gap is how alert copy shipped
    /// an em-dash while this check stayed green. Comments are skipped wherever
    /// they appear, because a quote inside one would otherwise corrupt the
    /// scan's string tracking for everything after it.
    private func emDashLineNumbers(in contents: String) -> [Int] {
        var offenders: [Int] = []
        var inMultilineString = false
        var inString = false
        var escaped = false
        var blockCommentDepth = 0
        var lineNumber = 1

        let characters = Array(contents)
        var i = 0

        func hasPrefix(_ text: String, at offset: Int) -> Bool {
            let prefix = Array(text)
            guard i + offset + prefix.count <= characters.count else {
                return false
            }
            for (index, expected) in prefix.enumerated()
            where characters[i + offset + index] != expected {
                return false
            }
            return true
        }

        while i < characters.count {
            let character = characters[i]

            if blockCommentDepth > 0 {
                if character == "*", hasPrefix("*/", at: 0) {
                    blockCommentDepth -= 1
                    i += 2
                    continue
                }
                if character == "/", hasPrefix("/*", at: 0) {
                    blockCommentDepth += 1
                    i += 2
                    continue
                }
            } else if inMultilineString {
                if character == "\"", hasPrefix("\"\"\"", at: 0) {
                    inMultilineString = false
                    i += 3
                    continue
                }
                if character == "—" {
                    offenders.append(lineNumber)
                }
            } else if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                } else if character == "—" {
                    offenders.append(lineNumber)
                }
            } else if character == "/", hasPrefix("//", at: 0) {
                while i < characters.count, characters[i] != "\n" {
                    i += 1
                }
                continue
            } else if character == "/", hasPrefix("/*", at: 0) {
                blockCommentDepth = 1
                i += 2
                continue
            } else if character == "\"", hasPrefix("\"\"\"", at: 0) {
                inMultilineString = true
                i += 3
                continue
            } else if character == "\"" {
                inString = true
            }

            if character == "\n" {
                lineNumber += 1
            }
            i += 1
        }

        return offenders
    }

    private func swiftFiles() throws -> [URL] {
        // Walks up from this file to the repository, so the check runs against
        // the sources rather than anything baked into the test bundle.
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Nook")

        guard let enumerator = FileManager.default.enumerator(
            at: sources,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        return enumerator.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
    }

    /// The repository's `project.yml`, found the same way `swiftFiles()`
    /// finds the sources: by walking up from this file rather than assuming
    /// a working directory.
    private func projectYML() throws -> URL {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("project.yml")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return url
    }
}
