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

        for file in try swiftFiles() {
            let name = file.lastPathComponent
            guard !Self.allowedFiles.contains(name) else { continue }

            let contents = try String(contentsOf: file, encoding: .utf8)
            for (index, line) in contents.split(
                separator: "\n",
                omittingEmptySubsequences: false
            ).enumerated() {
                let text = String(line)
                guard text.contains("—") else { continue }
                // Comments and documentation are free to use them.
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//") else { continue }
                // Diagnostics are not shown to anyone in a release build.
                guard !text.contains("DictationDebugLog") else { continue }
                guard containsEmDashInsideAStringLiteral(text) else { continue }
                offenders.append("\(name):\(index + 1): \(trimmed)")
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

    /// Whether an em-dash on this line falls between quotes.
    ///
    /// Deliberately simple: it walks the line tracking whether it is inside a
    /// string, which is enough for real source and cannot be fooled in a way
    /// that produces a false failure.
    private func containsEmDashInsideAStringLiteral(_ line: String) -> Bool {
        var insideString = false
        var previous: Character?
        for character in line {
            if character == "\"", previous != "\\" {
                insideString.toggle()
            } else if character == "—", insideString {
                return true
            }
            previous = character
        }
        return false
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
}
