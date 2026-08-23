import Foundation
import Testing
@testable import Nook

/// Action items gain a due date as a plain-text suffix that survives every
/// round-trip: toggling, editing by hand, and re-decoding. The open-actions
/// list sorts dated items ahead of undated ones so deadlines lead.
@MainActor
struct ActionItemDueDateTests {
    private func markdownWithActions() -> String {
        """
        ---
        id: \(UUID().uuidString)
        started: 2026-08-20T09:00:00Z
        ended: 2026-08-20T10:00:00Z
        ---

        # Review

        ## Summary

        Talked it through.

        ## Key points

        _None captured._

        ## Decisions

        _None captured._

        ## Action items

        - [ ] Draft the migration note [due: 2026-09-12]
        - [ ] Book load testing
        - [x] Circulate the agenda

        ## My notes

        _No personal notes._
        """
    }

    @Test
    func aDueSuffixParsesIntoADateAndStripsForDisplay() throws {
        let lines = MarkdownCodec.actionItemLines(in: markdownWithActions())
        let dated = try #require(lines.first { $0.index == 0 })

        let due = try #require(dated.dueDate)
        let components = Calendar.current.dateComponents(
            [.year, .month, .day],
            from: due
        )
        #expect(components.year == 2_026)
        #expect(components.month == 9)
        #expect(components.day == 12)

        // Display wording loses the bookkeeping entirely.
        #expect(dated.displayText == "Draft the migration note")
        #expect(lines[1].dueDate == nil)
        #expect(lines[1].displayText == "Book load testing")
        // Checked state is untouched by the suffix.
        #expect(lines[1].isChecked == false)
        #expect(lines[2].isChecked == true)
    }

    @Test
    func settingAndClearingADueDateRewritesOneLineOnly() throws {
        let markdown = markdownWithActions()
        let lines = MarkdownCodec.actionItemLines(in: markdown)
        let undated = try #require(lines.first { $0.index == 1 })
        var target = Date(timeIntervalSince1970: 1_788_480_000) // 2026-09-04 UTC-ish; day precision asserted below
        target = Calendar.current.startOfDay(for: target)

        let withDate = try #require(
            MarkdownCodec.markdownBySettingActionItemDue(
                undated,
                dueTo: target,
                in: markdown
            )
        )

        // The dated sibling line and everything around it did not move.
        #expect(withDate.contains("- [ ] Draft the migration note [due: 2026-09-12]"))
        #expect(withDate.contains("## My notes"))
        let updatedLines = MarkdownCodec.actionItemLines(in: withDate)
        #expect(updatedLines.count == 3)
        let changed = try #require(updatedLines.first { $0.index == 1 })
        let applied = try #require(changed.dueDate)
        #expect(
            Calendar.current.isDate(
                applied,
                inSameDayAs: target
            )
        )
        #expect(changed.displayText == "Book load testing")

        // Clearing removes the suffix and nothing else.
        let cleared = try #require(
            MarkdownCodec.markdownBySettingActionItemDue(
                changed,
                dueTo: nil,
                in: withDate
            )
        )
        let clearedLines = MarkdownCodec.actionItemLines(in: cleared)
        #expect(clearedLines[1].dueDate == nil)
        #expect(clearedLines.first { $0.index == 0 }?.dueDate != nil)
    }

    @Test
    func aStaleItemIsRefusedRatherThanRewritten() {
        let markdown = markdownWithActions()
        let stale = ActionItemLine(
            index: 1,
            text: "Book load testing [due: 2020-01-01]",
            isChecked: false
        )

        #expect(
            MarkdownCodec.markdownBySettingActionItemDue(
                stale,
                dueTo: Date(),
                in: markdown
            ) == nil
        )
    }

    @Test
    func togglingAnItemKeepsItsDueDate() throws {
        let markdown = markdownWithActions()
        let dated = try #require(
            MarkdownCodec.actionItemLines(in: markdown)
                .first { $0.index == 0 }
        )

        let rewritten = try #require(
            MarkdownCodec.markdownBySettingActionItem(
                dated,
                checked: true,
                in: markdown
            )
        )

        let lines = MarkdownCodec.actionItemLines(in: rewritten)
        let toggled = try #require(lines.first { $0.index == 0 })
        #expect(toggled.isChecked)
        #expect(toggled.dueDate != nil)
        #expect(toggled.displayText == "Draft the migration note")
    }

    @Test
    func datedItemsLeadTheListByDeadlineThenUndatedByRecency() {
        func action(_ text: String, daysAgo: Int, dueIn: Int?) -> OpenAction {
            OpenAction(
                noteID: UUID(),
                itemIndex: 0,
                text: text + (dueIn.map {
                    " [due: \(ISO8601DateFormatter().string(from: Date().addingTimeInterval(Double($0) * 86_400)).prefix(10))]"
                } ?? ""),
                dueDate: dueIn.map { Date().addingTimeInterval(Double($0) * 86_400) },
                noteTitle: "Meeting",
                startedAt: Date().addingTimeInterval(-Double(daysAgo) * 86_400)
            )
        }

        let sorted = OpenActionsController.sortedByDueUrgency([
            action("Undated recent", daysAgo: 1, dueIn: nil),
            action("Undated old", daysAgo: 30, dueIn: nil),
            action("Due later", daysAgo: 2, dueIn: 10),
            action("Overdue badly", daysAgo: 5, dueIn: -4),
            action("Due sooner", daysAgo: 9, dueIn: 2),
        ])

        #expect(sorted.map(\.displayText) == [
            "Overdue badly",
            "Due sooner",
            "Due later",
            "Undated recent",
            "Undated old",
        ])
    }

    @Test
    func chipsNameTodayTomorrowAndLapse() {
        let calendar = Calendar.current
        let now = Date()

        let overdue = OpenAction(
            noteID: UUID(), itemIndex: 0,
            text: "x", dueDate: now.addingTimeInterval(-3 * 86_400),
            noteTitle: "M", startedAt: now
        )
        #expect(overdue.dueChip(asOf: now).isOverdue)

        let today = OpenAction(
            noteID: UUID(), itemIndex: 0,
            text: "x", dueDate: now,
            noteTitle: "M", startedAt: now
        )
        #expect(today.dueChip(asOf: now).text == "Due today")
        #expect(!today.dueChip(asOf: now).isOverdue)

        let tomorrow = OpenAction(
            noteID: UUID(), itemIndex: 0,
            text: "x",
            dueDate: calendar.date(byAdding: .day, value: 1, to: now),
            noteTitle: "M", startedAt: now
        )
        #expect(tomorrow.dueChip(asOf: now).text == "Due tomorrow")
    }
}
