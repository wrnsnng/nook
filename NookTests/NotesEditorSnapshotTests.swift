import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Nook

/// Native editor integration preserves exact text and selection, and only
/// explicit requests may take keyboard focus from another control.
@MainActor
struct NotesEditorSnapshotTests {
    private func editor(containing text: String) -> NSTextView {
        let textView = NSTextView(frame: .zero)
        textView.isRichText = false
        textView.string = text
        return textView
    }

    @Test
    func snapshotsPreserveExactUTF8IncludingEmptyTextAndUnicodeClusters() {
        let samples = [
            "",
            "  Keep the surrounding whitespace.\n\n",
            "Caf\u{00E9}",
            "Cafe\u{0301}",
            "👩🏽‍💻 👨‍👩‍👧‍👦 🏳️‍🌈 🇦🇺",
            " \u{0301}\t\u{20DD}\u{202F}\u{FE0F}\n",
            "First line\r\nSecond line\rThird line\n",
            String(repeating: "  Cafe\u{0301} 👩🏽‍💻\r\n", count: 64)
        ]
        for original in samples {
            let textView = editor(containing: original)

            let snapshot = NookNotesEditor.textSnapshot(from: textView)

            #expect(Data(snapshot.utf8) == Data(original.utf8))
            // This is the boundary's performance contract in addition to
            // its byte-for-byte text contract. No lazy UTF-16 bridge remains.
            let contiguousByteCount = snapshot.utf8.withContiguousStorageIfAvailable { $0.count }
            #expect(contiguousByteCount == original.utf8.count)
        }
    }

    @Test
    func canonicallyEquivalentEditsRemainDistinctSnapshots() {
        let composed = "Caf\u{00E9} review"
        let decomposed = "Cafe\u{0301} review"
        let textView = editor(containing: composed)
        let first = NookNotesEditor.textSnapshot(from: textView)
        textView.string = decomposed

        let second = NookNotesEditor.textSnapshot(from: textView)

        #expect(first == second)
        #expect(Data(first.utf8) == Data(composed.utf8))
        #expect(Data(second.utf8) == Data(decomposed.utf8))
        #expect(Data(first.utf8) != Data(second.utf8))
    }

    @Test
    func readingASnapshotLeavesNativeTextAndSelectionUnchanged() {
        let original = "Start 👩🏽‍💻 Cafe\u{0301}\r\nFinish"
        let textView = editor(containing: original)
        let native = original as NSString
        let selections = [
            NSRange(location: 0, length: 0),
            native.range(of: "👩🏽‍💻"),
            NSRange(location: native.length, length: 0),
            NSRange(location: 0, length: native.length)
        ]
        for selection in selections {
            textView.setSelectedRange(selection)
            let selectedRanges = textView.selectedRanges

            let snapshot = NookNotesEditor.textSnapshot(from: textView)

            #expect(Data(snapshot.utf8) == Data(original.utf8))
            #expect(Data(textView.string.utf8) == Data(original.utf8))
            #expect(textView.selectedRanges == selectedRanges)
            #expect(textView.selectedRange() == selection)
        }
    }

    @Test
    func laterNativeStorageEditsCannotChangeAnEarlierSnapshot() throws {
        let original = "  Caf\u{00E9} 👩🏽‍💻\r\nKeep this line.\r\n"
        let textView = editor(containing: original)
        let storage = try #require(textView.textStorage)
        let first = NookNotesEditor.textSnapshot(from: textView)
        let titleRange = (storage.string as NSString).range(of: "Caf\u{00E9}")
        storage.beginEditing()
        storage.replaceCharacters(in: titleRange, with: "Cafe\u{0301}")
        storage.append(NSAttributedString(string: "Added 🏳️‍🌈.\n"))
        storage.endEditing()
        let edited = "  Cafe\u{0301} 👩🏽‍💻\r\nKeep this line.\r\nAdded 🏳️‍🌈.\n"
        let second = NookNotesEditor.textSnapshot(from: textView)

        #expect(Data(textView.string.utf8) == Data(edited.utf8))
        #expect(Data(first.utf8) == Data(original.utf8))
        #expect(Data(second.utf8) == Data(edited.utf8))

        storage.deleteCharacters(in: NSRange(location: 0, length: storage.length))

        #expect(textView.string.isEmpty)
        #expect(NookNotesEditor.textSnapshot(from: textView).isEmpty)
        #expect(Data(first.utf8) == Data(original.utf8))
        #expect(Data(second.utf8) == Data(edited.utf8))
    }

    @Test
    func programmaticReplacementReachesTheEditorForEquivalentUnicode() {
        let composed = "Caf\u{00E9} tomorrow"
        let decomposed = "Cafe\u{0301} tomorrow"
        let textView = editor(containing: composed)
        let selection = NSRange(location: 0, length: 3)
        textView.setSelectedRange(selection)
        #expect(composed == decomposed)

        NookNotesEditor.synchronizeText(decomposed, in: textView)

        #expect(Data(textView.string.utf8) == Data(decomposed.utf8))
        #expect(textView.selectedRange() == selection)
        NookNotesEditor.synchronizeText(composed, in: textView)
        #expect(Data(textView.string.utf8) == Data(composed.utf8))
    }

    @Test
    func shorterReplacementsClampSelectionToTheNewBuffer() {
        let textView = editor(containing: "A longer thought")
        textView.setSelectedRange(NSRange(location: 9, length: 5))
        NookNotesEditor.synchronizeText("Short", in: textView)
        #expect(textView.string == "Short")
        #expect(textView.selectedRange() == NSRange(location: 5, length: 0))
        NookNotesEditor.synchronizeText("", in: textView)
        #expect(textView.string.isEmpty)
        #expect(textView.selectedRange() == NSRange(location: 0, length: 0))
    }

    @Test
    func identicalBindingsDoNotReplaceNativeStorageOrSelection() throws {
        let original = "Keep 👩🏽‍💻 and Cafe\u{0301} exactly."
        let textView = editor(containing: original)
        let storage = try #require(textView.textStorage)
        let marker = NSAttributedString.Key("NookSnapshotTestMarker")
        storage.addAttribute(marker, value: "retained", range: NSRange(location: 0, length: 1))
        let selection = NSRange(location: 0, length: 4)
        textView.setSelectedRange(selection)

        NookNotesEditor.synchronizeText(original, in: textView)

        #expect(storage.attribute(marker, at: 0, effectiveRange: nil) as? String == "retained")
        #expect(textView.selectedRange() == selection)
        #expect(Data(textView.string.utf8) == Data(original.utf8))
    }

    @Test
    func anEditorWithoutAnExplicitFocusRequestLeavesTheCurrentControlAlone() throws {
        let fixture = focusFixture()
        defer { fixture.window.close() }
        try #require(fixture.window.makeFirstResponder(fixture.otherControl))
        var appliedToken = 0

        let request = NookNotesEditor.requestFocus(
            0, appliedToken: &appliedToken, in: fixture.editor
        )

        #expect(request == nil)
        #expect(fixture.window.firstResponder === fixture.otherControl)
        #expect(!fixture.window.isVisible)
    }

    @Test
    func explicitFocusRequestsWorkOnceWithoutStealingFocusBackOnLaterUpdates() async throws {
        let fixture = focusFixture()
        defer { fixture.window.close() }
        let original = "Synthetic Caf\u{00E9} focus check."
        fixture.editor.string = original
        let selection = NSRange(location: 10, length: 4)
        fixture.editor.setSelectedRange(selection)
        var appliedToken = 0

        // The second request represents explicitly raising the same pad again.
        for token in [1, 2] {
            try #require(fixture.window.makeFirstResponder(fixture.otherControl))
            let request = try #require(NookNotesEditor.requestFocus(
                token, appliedToken: &appliedToken, in: fixture.editor
            ))
            await request.value
            #expect(fixture.window.firstResponder === fixture.editor)
            #expect(fixture.editor.selectedRange() == selection)
            #expect(Data(fixture.editor.string.utf8) == Data(original.utf8))

            // A toolbar or another field now owns focus. Ordinary representable
            // updates with the same token must neither schedule work nor reclaim it.
            try #require(fixture.window.makeFirstResponder(fixture.otherControl))
            NookNotesEditor.synchronizeText(original, in: fixture.editor)
            let repeated = NookNotesEditor.requestFocus(
                token, appliedToken: &appliedToken, in: fixture.editor
            )
            #expect(repeated == nil)
            #expect(fixture.window.firstResponder === fixture.otherControl)
        }
        #expect(!fixture.window.isVisible)
    }

    @Test
    func aDisabledEditorDoesNotConsumeOrApplyThePendingFocusRequest() async throws {
        let fixture = focusFixture()
        defer { fixture.window.close() }
        try #require(fixture.window.makeFirstResponder(fixture.otherControl))
        fixture.editor.isEditable = false
        var appliedToken = 0

        let blocked = NookNotesEditor.requestFocus(
            1, appliedToken: &appliedToken, in: fixture.editor
        )
        #expect(blocked == nil)
        #expect(appliedToken == 0)
        #expect(fixture.window.firstResponder === fixture.otherControl)

        fixture.editor.isEditable = true
        let request = try #require(NookNotesEditor.requestFocus(
            1, appliedToken: &appliedToken, in: fixture.editor
        ))
        await request.value
        #expect(fixture.window.firstResponder === fixture.editor)
        #expect(!fixture.window.isVisible)
    }

    @Test(arguments: [340.0, 595.0])
    func theHostedEditorKeepsItsTextSystemAndSelectionAcrossLayoutUpdates(width: Double) async throws {
        let original = "Cafe\u{0301} 👩🏽‍💻\r\nעברית العربية\nKeep this line."
        let fixture = try await hostedFixture(containing: original, width: width)
        defer { fixture.window.close() }
        let editor = fixture.editor
        // Read the modern getter first. Obtaining layoutManager on a TextKit 2
        // editor would itself switch engines and invalidate this assertion.
        try #require(editor.textLayoutManager == nil)
        #expect(editor.layoutManager?.allowsNonContiguousLayout == false)
        #expect(editor.textStorage != nil)
        #expect(!editor.isRichText)
        #expect(editor.allowsUndo)
        #expect(editor.textContainer?.lineFragmentPadding == 0)
        #expect(editor.textContainer?.widthTracksTextView == true)
        #expect(editor.defaultParagraphStyle?.lineSpacing == 2)
        #expect(editor.accessibilityLabel() == "Synthetic native notes editor")
        let selection = (original as NSString).range(of: "👩🏽‍💻")
        editor.setSelectedRange(selection)

        for nextWidth in [width + 60, width] {
            fixture.host.frame.size.width = nextWidth
            try await renderUnrelatedUpdate(in: fixture)
            #expect(editors(in: fixture.host).first === editor)
            #expect(editor.textLayoutManager == nil)
            #expect(editor.selectedRange() == selection)
            #expect(editor.string.utf8.elementsEqual(original.utf8))
            #expect(fixture.model.text.utf8.elementsEqual(original.utf8))
            #expect(fixture.window.firstResponder === editor)
            #expect(editor.bounds.width > 0)
        }
        #expect(!fixture.window.isVisible)
    }

    @Test
    func accessibilityCanReadTheCompleteLongNoteBeyondTheVisibleViewport() async throws {
        let paragraph = Array(repeating: "Review Cafe\u{0301} planning next", count: 2_500)
            .joined(separator: " ")
        let start = "Start Caf\u{00E9} 👩🏽‍💻\r\n"
        let middle = "Middle עברית العربية 🏳️‍🌈\r\n"
        let end = "End Cafe\u{0301} 🇦🇺\r\n"
        let original = start + paragraph + "\r\n" + middle + paragraph + "\r\n" + end
        let native = original as NSString
        let completeRange = NSRange(location: 0, length: native.length)
        let samples = [start, middle, end].map { native.range(of: $0) }
        let fixture = try await hostedFixture(containing: original)
        defer { fixture.window.close() }
        let editor = fixture.editor
        let selection = native.range(of: "👩🏽‍💻")
        editor.setSelectedRange(selection)
        try #require(editor.textLayoutManager == nil)

        for (index, width) in [340.0, 595.0, 460.0].enumerated() {
            fixture.host.frame.size.width = width
            try await renderUnrelatedUpdate(in: fixture)
            // Visit the end, middle and start. At each viewport, read every
            // marker, including those outside the visible part of the note.
            let destination = samples[samples.count - 1 - index]
            editor.scrollRangeToVisible(destination)
            try await settleLayout(in: fixture.host) {
                NSLocationInRange(destination.location, editor.accessibilityVisibleCharacterRange())
            }
            let visible = editor.accessibilityVisibleCharacterRange()
            try #require(visible.location != NSNotFound)
            try #require(NSMaxRange(visible) <= native.length)
            #expect(visible.length < native.length)
            #expect(samples.contains { NSIntersectionRange($0, visible).length == 0 })
            #expect(editor.accessibilityNumberOfCharacters() == native.length)
            let completeText = try #require(editor.accessibilityString(for: completeRange))
            #expect(completeText.utf8.elementsEqual(original.utf8))
            for sample in samples {
                let accessible = try #require(editor.accessibilityString(for: sample))
                #expect(accessible.utf8.elementsEqual(native.substring(with: sample).utf8))
            }

            // AppKit can expose a viewport value while its range API exposes
            // the complete document. Either value must contain the exact
            // original text, including Unicode encoding and CRLF sequences.
            let value = try #require(editor.accessibilityValue())
            #expect(
                value.utf8.elementsEqual(original.utf8)
                    || value.utf8.elementsEqual(native.substring(with: visible).utf8)
            )
            #expect(editor.selectedRange() == selection)
            #expect(editor.string.utf8.elementsEqual(original.utf8))
            #expect(fixture.model.text.utf8.elementsEqual(original.utf8))
            #expect(editors(in: fixture.host).first === editor)
            #expect(editor.textLayoutManager == nil)
        }
        #expect(!fixture.window.isVisible)
    }

    @Test(arguments: ["start", "middle", "end", "selection", "delete", "long paragraph"])
    func nativeEditsAndUndoRedoPreserveExactWordsAndSelection(operation: String) async throws {
        let original = operation == "long paragraph"
            ? Array(repeating: "Review cafe\u{0301} planning next", count: 5_000).joined(separator: " ")
            : "Start Cafe\u{0301} 👩🏽‍💻\r\nעברית العربية\nFinish"
        let fixture = try await hostedFixture(containing: original)
        defer { fixture.window.close() }
        let editor = fixture.editor
        let native = original as NSString
        let selection: NSRange
        let replacement: String
        switch operation {
        case "start":
            selection = NSRange(location: 0, length: 0)
            replacement = "Caf\u{00E9} "
        case "middle":
            selection = NSRange(location: native.range(of: "👩🏽‍💻").location, length: 0)
            replacement = "会議 🌱 "
        case "selection":
            selection = native.range(of: "Cafe\u{0301} 👩🏽‍💻")
            replacement = "Caf\u{00E9} 🏳️‍🌈"
        case "delete":
            selection = native.range(of: "👩🏽‍💻")
            replacement = ""
        default:
            selection = NSRange(location: native.length, length: 0)
            replacement = operation == "long paragraph" ? " confirmed" : "\r\nCafe\u{0301} 🇦🇺"
        }
        let expected = native.replacingCharacters(in: selection, with: replacement)
        editor.setSelectedRange(selection)
        let undo = try #require(editor.undoManager)
        undo.removeAllActions()
        // Group this one synthetic command explicitly. Natural typing-event
        // coalescing remains a separate interactive acceptance check.
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        if operation == "delete" {
            editor.deleteBackward(nil)
        } else {
            editor.insertText(replacement, replacementRange: selection)
        }
        editor.breakUndoCoalescing()
        undo.endUndoGrouping()
        try await settleLayout(in: fixture.host) {
            fixture.model.text.utf8.elementsEqual(expected.utf8)
        }
        let editedSelection = NSRange(
            location: selection.location + (replacement as NSString).length,
            length: 0
        )
        #expect(editor.string.utf8.elementsEqual(expected.utf8))
        #expect(editor.selectedRange() == editedSelection)
        #expect(undo.canUndo)
        try await renderUnrelatedUpdate(in: fixture)

        undo.undo()
        try await settleLayout(in: fixture.host) {
            fixture.model.text.utf8.elementsEqual(original.utf8)
        }
        #expect(editor.string.utf8.elementsEqual(original.utf8))
        #expect(editor.selectedRange() == selection)
        #expect(undo.canRedo)
        undo.redo()
        try await settleLayout(in: fixture.host) {
            fixture.model.text.utf8.elementsEqual(expected.utf8)
        }
        #expect(editor.string.utf8.elementsEqual(expected.utf8))
        #expect(editor.selectedRange() == editedSelection)
        #expect(editors(in: fixture.host).first === editor)
        #expect(editor.textLayoutManager == nil)
        #expect(!fixture.window.isVisible)
    }

    @Test(arguments: ["start", "middle", "selection"])
    func checklistCommandsInsertAtTheCaretWithoutDeletingSelectedWords(position: String) async throws {
        let original = "First Cafe\u{0301}\r\nSecond 👩🏽‍💻 line."
        let fixture = try await hostedFixture(containing: original)
        defer { fixture.window.close() }
        let editor = fixture.editor
        let native = original as NSString
        let selection: NSRange
        let insertion: String
        switch position {
        case "start":
            selection = NSRange(location: 0, length: 0)
            insertion = "- [ ] "
        case "middle":
            selection = NSRange(location: native.range(of: "👩🏽‍💻").location, length: 0)
            insertion = "\n- [ ] "
        default:
            selection = native.range(of: "Second 👩🏽‍💻")
            insertion = "- [ ] "
        }
        editor.setSelectedRange(selection)
        let expected = native.replacingCharacters(
            in: NSRange(location: selection.location, length: 0), with: insertion
        )
        let undo = try #require(editor.undoManager)
        undo.removeAllActions()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        fixture.model.insertionPort.insertLineStarting(with: "- [ ] ")
        editor.breakUndoCoalescing()
        undo.endUndoGrouping()
        try await settleLayout(in: fixture.host) {
            fixture.model.text.utf8.elementsEqual(expected.utf8)
        }
        #expect(editor.string.utf8.elementsEqual(expected.utf8))
        #expect(editor.selectedRange() == NSRange(
            location: selection.location + (insertion as NSString).length,
            // The command inserts before selected words. AppKit keeps those
            // same words selected, so a checklist prefix does not erase them.
            length: selection.length
        ))
        #expect(undo.canUndo)
        undo.undo()
        try await settleLayout(in: fixture.host) {
            fixture.model.text.utf8.elementsEqual(original.utf8)
        }
        #expect(editor.string.utf8.elementsEqual(original.utf8))
        #expect(editor.textLayoutManager == nil)
    }

    @Test
    func bindingDrivenUpdatesKeepExactTextAndTheExistingNativeEditor() async throws {
        let original = "Review Caf\u{00E9} 👩🏽‍💻\r\nKeep my context."
        let fixture = try await hostedFixture(containing: original)
        defer { fixture.window.close() }
        let editor = fixture.editor
        let selection = (original as NSString).range(of: "Keep")
        editor.setSelectedRange(selection)
        // Dictation in the pad changes its binding; this exercises that editor
        // boundary without pretending to test microphones, AX or paste delivery.
        let appended = original + "\r\nSpoken addition العربية."
        fixture.model.text = appended
        try await settleLayout(in: fixture.host) { editor.string.utf8.elementsEqual(appended.utf8) }
        #expect(editor.selectedRange() == selection)

        let decomposed = appended.replacingOccurrences(of: "Caf\u{00E9}", with: "Cafe\u{0301}")
        #expect(decomposed == appended)
        fixture.model.text = decomposed
        try await settleLayout(in: fixture.host) { editor.string.utf8.elementsEqual(decomposed.utf8) }
        #expect(editor.string.utf8.elementsEqual(decomposed.utf8))
        #expect(editor.selectedRange() == selection)
        fixture.model.text = appended
        try await settleLayout(in: fixture.host) { editor.string.utf8.elementsEqual(appended.utf8) }
        try await renderUnrelatedUpdate(in: fixture)
        #expect(editor.string.utf8.elementsEqual(appended.utf8))
        #expect(fixture.model.text.utf8.elementsEqual(appended.utf8))
        #expect(editor.selectedRange() == selection)

        fixture.model.text = "雪"
        try await settleLayout(in: fixture.host) { editor.string == "雪" }
        #expect(editor.selectedRange() == NSRange(location: 1, length: 0))
        #expect(editors(in: fixture.host).first === editor)
        #expect(editor.textLayoutManager == nil)
        #expect(fixture.window.firstResponder === editor)
    }

    @Test(arguments: ["日本語", "中文", "한국어", "Cafe\u{0301}"])
    func simulatedCompositionSurvivesUnrelatedUpdatesUntilItIsCommitted(committed: String) async throws {
        let original = "Before 👩🏽‍💻 after\r\nKeep this line."
        let fixture = try await hostedFixture(containing: original)
        defer { fixture.window.close() }
        let editor = fixture.editor
        let replacement = (original as NSString).range(of: "after")
        editor.setSelectedRange(replacement)
        // Drive the native input-client protocol, not a physical input source.
        // Candidate windows, dead keys and real CJK keyboards still need hands-on acceptance.
        let first = "仮"
        editor.setMarkedText(
            first, selectedRange: NSRange(location: (first as NSString).length, length: 0),
            replacementRange: replacement
        )
        try #require(editor.hasMarkedText())
        let firstRange = editor.markedRange()
        let firstSelection = editor.selectedRange()
        let firstText = (original as NSString).replacingCharacters(in: replacement, with: first)
        try await renderUnrelatedUpdate(in: fixture)
        #expect(editor.hasMarkedText())
        #expect(editor.markedRange() == firstRange)
        #expect(editor.selectedRange() == firstSelection)
        #expect(editor.string.utf8.elementsEqual(firstText.utf8))

        editor.setMarkedText(
            committed, selectedRange: NSRange(location: (committed as NSString).length, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        try #require(editor.hasMarkedText())
        let expected = (original as NSString).replacingCharacters(in: replacement, with: committed)
        try await renderUnrelatedUpdate(in: fixture)
        #expect(editor.hasMarkedText())
        #expect(editor.string.utf8.elementsEqual(expected.utf8))
        editor.insertText(committed, replacementRange: NSRange(location: NSNotFound, length: 0))
        try await settleLayout(in: fixture.host) {
            fixture.model.text.utf8.elementsEqual(expected.utf8)
        }
        #expect(!editor.hasMarkedText())
        #expect(editor.string.utf8.elementsEqual(expected.utf8))
        #expect(editor.selectedRange() == NSRange(
            location: replacement.location + (committed as NSString).length, length: 0
        ))
        try await renderUnrelatedUpdate(in: fixture)
        #expect(!editor.hasMarkedText())
        #expect(editor.string.utf8.elementsEqual(expected.utf8))
        #expect(fixture.model.text.utf8.elementsEqual(expected.utf8))
        #expect(editors(in: fixture.host).first === editor)
        #expect(editor.textLayoutManager == nil)
        #expect(!fixture.window.isVisible)
    }

    @Test(arguments: [false, true])
    func endingSimulatedCompositionKeepsTheCommittedOrCancelledText(cancelled: Bool) async throws {
        let original = "Before 👩🏽‍💻\r\nAfter Cafe\u{0301}."
        let fixture = try await hostedFixture(containing: original)
        defer { fixture.window.close() }
        let editor = fixture.editor
        let insertion = NSRange(location: (original as NSString).range(of: "After").location, length: 0)
        editor.setSelectedRange(insertion)
        let composed = "日本語 "
        editor.setMarkedText(
            composed, selectedRange: NSRange(location: (composed as NSString).length, length: 0),
            replacementRange: insertion
        )
        try #require(editor.hasMarkedText())
        try await renderUnrelatedUpdate(in: fixture)
        #expect(editor.hasMarkedText())
        if cancelled {
            // An input client can discard its temporary insertion and remove
            // the mark. This is protocol simulation, not an Escape-key test.
            editor.setMarkedText(
                "", selectedRange: NSRange(location: 0, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0)
            )
        }
        editor.unmarkText()
        let expected = cancelled
            ? original
            : (original as NSString).replacingCharacters(in: insertion, with: composed)
        try await settleLayout(in: fixture.host) {
            fixture.model.text.utf8.elementsEqual(expected.utf8)
        }
        #expect(!editor.hasMarkedText())
        #expect(editor.string.utf8.elementsEqual(expected.utf8))
        #expect(editor.selectedRange() == NSRange(
            location: insertion.location + (cancelled ? 0 : (composed as NSString).length), length: 0
        ))
        try await renderUnrelatedUpdate(in: fixture)
        #expect(editor.string.utf8.elementsEqual(expected.utf8))
        #expect(fixture.model.text.utf8.elementsEqual(expected.utf8))
        #expect(editors(in: fixture.host).first === editor)
        #expect(editor.textLayoutManager == nil)
    }

    @Test
    func disablingAndReenablingTheHostedEditorKeepsItsTextSystemAndFocusContract() async throws {
        let original = "Keep my Cafe\u{0301} note."
        let fixture = try await hostedFixture(containing: original)
        defer { fixture.window.close() }
        let editor = fixture.editor
        fixture.model.isEnabled = false
        try await settleLayout(in: fixture.host) { !editor.isEditable }
        #expect(fixture.window.firstResponder !== editor)
        fixture.model.isEnabled = true
        fixture.model.focusToken += 1
        try await settleLayout(in: fixture.host) {
            editor.isEditable && fixture.window.firstResponder === editor
        }
        #expect(editor.string.utf8.elementsEqual(original.utf8))
        #expect(editors(in: fixture.host).first === editor)
        #expect(editor.textLayoutManager == nil)
    }

    @Test
    func reviewedVoiceReplacementIsOneExactNativeUndoableEdit() async throws {
        let original = "Baseline Cafe\u{0301} 👩🏽‍💻\r\nעברית scratch that"
        let replacement = "Baseline Cafe\u{0301} 👩🏽‍💻"
        let fixture = try await hostedFixture(containing: original)
        defer { fixture.window.close() }
        let undo = try #require(fixture.editor.undoManager)
        undo.removeAllActions()
        undo.groupsByEvent = false
        #expect(fixture.model.insertionPort.replaceText(
            expected: original, with: replacement, actionName: "Voice Correction"
        ) == .applied)
        try await settleLayout(in: fixture.host) { fixture.model.text.utf8.elementsEqual(replacement.utf8) }
        #expect(undo.canUndo)
        #expect(undo.undoActionName == "Voice Correction")
        undo.undo()
        try await settleLayout(in: fixture.host) { fixture.model.text.utf8.elementsEqual(original.utf8) }
        #expect(fixture.editor.string.utf8.elementsEqual(original.utf8))
        #expect(!undo.canUndo)
        #expect(undo.canRedo)
        undo.redo()
        try await settleLayout(in: fixture.host) { fixture.model.text.utf8.elementsEqual(replacement.utf8) }
        #expect(fixture.editor.string.utf8.elementsEqual(replacement.utf8))
    }

    @Test(arguments: ["stale", "unicode", "disabled", "composition"])
    func voiceReplacementRefusesStaleDisabledOrComposingNativeText(reason: String) async throws {
        let original = "Cafe\u{0301} review"
        let fixture = try await hostedFixture(containing: original)
        defer { fixture.window.close() }
        var expected = original
        switch reason {
        case "stale": expected += " missing words"
        case "unicode": expected = "Caf\u{00e9} review"
        case "disabled":
            fixture.model.isEnabled = false
            try await settleLayout(in: fixture.host) { !fixture.editor.isEditable }
        default:
            fixture.editor.setMarkedText(
                "日本", selectedRange: NSRange(location: 2, length: 0),
                replacementRange: NSRange(location: 0, length: 0)
            )
            try #require(fixture.editor.hasMarkedText())
            expected = fixture.editor.string
        }
        let before = fixture.editor.string
        let selection = fixture.editor.selectedRange()
        #expect(fixture.model.insertionPort.replaceText(
            expected: expected, with: "Replacement", actionName: "Voice Correction"
        ) == .refused)
        #expect(fixture.editor.string.utf8.elementsEqual(before.utf8))
        #expect(fixture.editor.selectedRange() == selection)
        if reason == "composition" { #expect(fixture.editor.hasMarkedText()) }
    }

    private struct HostedFixture {
        let model: NativeNotesEditorFixtureModel
        let host: NSView
        let window: NSWindow
        let editor: NSTextView
    }

    private func hostedFixture(containing text: String, width: Double = 460) async throws -> HostedFixture {
        let model = NativeNotesEditorFixtureModel(text: text)
        let host = NSHostingView(rootView: NativeNotesEditorFixture(model: model))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 280)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: true
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        do {
            try await settleLayout(in: host) { (editors(in: host).first?.bounds.width ?? 0) > 0 }
            let editor = try #require(editors(in: host).first)
            try #require(window.makeFirstResponder(editor))
            return HostedFixture(model: model, host: host, window: window, editor: editor)
        } catch {
            window.close()
            throw error
        }
    }

    private func renderUnrelatedUpdate(in fixture: HostedFixture) async throws {
        fixture.model.renderPulse += 1
        let requested = fixture.model.renderPulse
        try await settleLayout(in: fixture.host) { fixture.model.observedRenderPulse == requested }
    }

    private func editors(in view: NSView) -> [NSTextView] {
        if let editor = view as? NSTextView { return [editor] }
        return view.subviews.flatMap { editors(in: $0) }
    }

    private func settleLayout(in host: NSView, until condition: () -> Bool) async throws {
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition(), "The hidden Nook editor did not reach the expected state.")
    }

    /// A hidden native window exercises AppKit's actual first-responder chain
    /// without activating Nook or opening any production window or coordinator.
    private func focusFixture() -> (window: NSWindow, editor: NSTextView, otherControl: NSTextView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled], backing: .buffered, defer: true
        )
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let editor = NSTextView(frame: NSRect(x: 0, y: 100, width: 400, height: 100))
        let otherControl = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        editor.isRichText = false
        otherControl.isRichText = false
        content.addSubview(editor)
        content.addSubview(otherControl)
        window.contentView = content
        return (window, editor, otherControl)
    }
}

@MainActor
private final class NativeNotesEditorFixtureModel: ObservableObject {
    @Published var text: String
    @Published var isEnabled = true
    @Published var isFocused = false
    @Published var focusToken = 0
    @Published var renderPulse = 0
    var observedRenderPulse = 0
    let insertionPort = TextViewInsertionPort()

    init(text: String) { self.text = text }
}

@MainActor
private struct NativeNotesEditorFixture: View {
    @ObservedObject var model: NativeNotesEditorFixtureModel

    var body: some View {
        NookNotesEditor(
            text: $model.text,
            placeholder: "Synthetic notes",
            isFocused: $model.isFocused,
            focusToken: model.focusToken,
            lineSpacing: 2,
            accessibilityLabel: "Synthetic native notes editor",
            insertionPort: model.insertionPort
        )
        .disabled(!model.isEnabled)
        .opacity(model.renderPulse.isMultiple(of: 2) ? 1 : 0.99)
        .onChange(of: model.renderPulse) { _, value in
            model.observedRenderPulse = value
        }
        .transaction { $0.disablesAnimations = true }
    }
}
