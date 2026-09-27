import Foundation

/// A folder Nook thinks a note belongs in, and the evidence for it.
struct FolderSuggestion: Hashable, Sendable {
    enum Signal: String, Hashable, Sendable {
        /// Earlier sittings of the same series are filed there.
        case series
        /// The folder's name appears in the title, or is a named speaker.
        case name
        /// The note's title shares its distinctive words with that folder's.
        case similarity
    }

    let folder: String
    let reason: String
    let signal: Signal
}

/// Suggests which existing folder a note in the library's root belongs in.
///
/// Deterministic and on-device on purpose. A language model would suggest
/// more, and some of it would be invented: a folder is where somebody keeps
/// their own work, and a confident wrong answer there costs more than no
/// answer. Every rule below therefore prefers silence to a guess. Only the
/// title, the series key and named speakers are read; transcripts and
/// summaries are not, which also keeps the index small enough to rebuild
/// whenever the library changes.
///
/// Signals, strongest first:
/// 1. Series: earlier sittings with the same `SeriesMatcher` key are
///    filed, and a clear majority of them in one folder.
/// 2. Name: every key word of a folder's name ("Massimo" in "1:1 Massimo",
///    or the owner in "Massimo’s ramblings") is in the title or is the name
///    of a speaker.
/// 3. Similarity: the title's words are, taken together, specific to one
///    folder's notes, by a TF-IDF-like score with a floor and a margin.
struct FolderSuggestionIndex: Sendable {
    /// What the index keeps of each note. Titles only, tokenized once.
    struct Entry: Sendable, Hashable {
        let id: UUID
        let folder: String?
        let seriesKey: String
        let tokens: Set<String>
        let startedAt: Date
    }

    private(set) var entries: [Entry]
    /// The folders that exist on disk right now. A note's folder that is not
    /// in this list is treated as the root: it cannot be suggested.
    let folders: [String]
    private let documentFrequency: [String: Int]
    private let folderSizes: [String: Int]
    private let folderTokenCounts: [String: [String: Int]]
    private let folderKeys: [(folder: String, key: FolderNameKey)]
    /// Lookups prepared once, so a suggestion costs a few dictionary reads
    /// rather than a pass over the library. The sidebar asks for one per
    /// visible row's Move To menu.
    private let bySeries: [String: [Entry]]
    private let byID: [UUID: Entry]
    private let byFolder: [String: [Entry]]

    init(entries: [Entry], folders: [String]) {
        let known = Set(folders)
        self.entries = entries.map { entry in
            guard let folder = entry.folder, !known.contains(folder) else { return entry }
            return Entry(
                id: entry.id, folder: nil, seriesKey: entry.seriesKey,
                tokens: entry.tokens, startedAt: entry.startedAt
            )
        }
        self.folders = folders
        var frequency: [String: Int] = [:]
        var sizes: [String: Int] = [:]
        var counts: [String: [String: Int]] = [:]
        for entry in self.entries {
            for token in entry.tokens { frequency[token, default: 0] += 1 }
            guard let folder = entry.folder else { continue }
            sizes[folder, default: 0] += 1
            for token in entry.tokens { counts[folder, default: [:]][token, default: 0] += 1 }
        }
        documentFrequency = frequency
        bySeries = Dictionary(grouping: self.entries.filter { !$0.seriesKey.isEmpty }, by: \.seriesKey)
        // Duplicated IDs (a copied file) keep the first; neither is a
        // candidate the library offers a suggestion for anyway.
        byID = Dictionary(self.entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        byFolder = Dictionary(grouping: self.entries.filter { $0.folder != nil }, by: { $0.folder! })
        folderSizes = sizes
        folderTokenCounts = counts
        folderKeys = folders.compactMap { name in
            FolderNameKey(folderName: name).map { (name, $0) }
        }
    }

    /// Builds the index from the library. Digests are compiled from other
    /// notes, so they are neither evidence nor candidates.
    init(notes: [MeetingNote], folders: [String], libraryURL: URL) {
        let entries = notes.compactMap { note -> Entry? in
            guard note.kind != .digest else { return nil }
            return Entry(
                id: note.id,
                folder: note.fileURL.flatMap { LibraryFolders.folderName(of: $0, in: libraryURL) },
                seriesKey: FolderSuggester.seriesKey(for: note.title),
                tokens: FolderSuggester.tokens(in: note.title),
                startedAt: note.startedAt
            )
        }
        self.init(entries: entries, folders: folders)
    }

    // MARK: - Suggestion

    /// At most one folder for a note at the library's root, or nil.
    func suggestion(for note: MeetingNote, isInFolder: Bool) -> FolderSuggestion? {
        guard !isInFolder, note.kind != .digest, !folders.isEmpty else { return nil }
        switch seriesEvidence(for: note) {
        case .folder(let folder, let filedCount):
            let reason = note.kind == .spoken
                ? "Earlier notes with this title are there"
                : (filedCount == 1
                    ? "An earlier meeting is filed there"
                    : "Earlier meetings are filed there")
            return FolderSuggestion(folder: folder, reason: reason, signal: .series)
        case .conflicting:
            // Earlier sittings disagree. Any other signal would be a guess
            // against the person's own, inconsistent, filing.
            return nil
        case .none:
            break
        }
        if let named = nameSuggestion(for: note) { return named }
        return similaritySuggestion(for: note)
    }

    // MARK: Series

    enum SeriesEvidence: Equatable {
        case none
        case conflicting
        case folder(String, filedCount: Int)
    }

    /// Earlier sittings of the note's series that are filed, if a clear
    /// majority (two thirds) of them share one folder.
    func seriesEvidence(for note: MeetingNote) -> SeriesEvidence {
        let key = FolderSuggester.seriesKey(for: note.title)
        guard !key.isEmpty else { return .none }
        let filed = (bySeries[key] ?? []).filter { $0.id != note.id && $0.folder != nil }
        guard !filed.isEmpty else { return .none }
        let counts = Dictionary(grouping: filed, by: { $0.folder! }).mapValues(\.count)
        let ranked = counts.sorted { $0.value > $1.value }
        guard let top = ranked.first else { return .none }
        if ranked.count > 1, ranked[1].value == top.value { return .conflicting }
        guard Double(top.value) / Double(filed.count) >= 2.0 / 3.0 else { return .conflicting }
        return .folder(top.key, filedCount: filed.count)
    }

    // MARK: Name

    private func nameSuggestion(for note: MeetingNote) -> FolderSuggestion? {
        let titleTokens = FolderSuggester.nameTokens(in: note.title)
        var speakerTokens: [String: String] = [:]
        for speaker in SpeakerNames.speakers(in: note.transcript) where !SpeakerNames.isPlaceholder(speaker) {
            for token in FolderSuggester.nameTokens(in: speaker) { speakerTokens[token] = speaker }
        }
        var matches: [(folder: String, key: FolderNameKey, inTitle: Bool)] = []
        for (folder, key) in folderKeys {
            if key.required.isSubset(of: titleTokens) {
                matches.append((folder, key, true))
            } else if key.required.isSubset(of: Set(speakerTokens.keys)) {
                matches.append((folder, key, false))
            }
        }
        // The most specific name wins; two equally specific names are
        // ambiguous, and ambiguity is answered with nothing.
        let best = matches.map(\.key.required.count).max() ?? 0
        let leaders = matches.filter { $0.key.required.count == best }
        guard leaders.count == 1, let match = leaders.first else { return nil }
        let reason: String
        if match.inTitle {
            reason = "The title mentions \(match.key.display)"
        } else {
            let speaker = match.key.required.compactMap { speakerTokens[$0] }.first ?? match.key.display
            reason = "\(speaker) speaks in this meeting"
        }
        return FolderSuggestion(folder: match.folder, reason: reason, signal: .name)
    }

    // MARK: Similarity

    /// Tuned for precision. A folder must hold at least two notes that share
    /// the title's words, the words must be mostly its own rather than common
    /// across the library, and the runner-up must be clearly behind.
    static let similarityFloor = 0.6
    static let similarityMargin = 0.25
    static let minimumSupportingNotes = 2

    struct SimilarityScore: Equatable {
        let folder: String
        let score: Double
        let matchedTokens: Int
        let supportingNotes: Int
    }

    func similarityScores(for note: MeetingNote) -> [SimilarityScore] {
        let tokens = FolderSuggester.tokens(in: note.title)
        // The candidate is usually in the index itself, and its own words
        // are not evidence for anything.
        let ownEntry = byID[note.id]
        let own = ownEntry?.tokens ?? []
        let otherCount = entries.count - (ownEntry == nil ? 0 : 1)
        guard otherCount > 0 else { return [] }
        func frequency(_ token: String) -> Int {
            (documentFrequency[token] ?? 0) - (own.contains(token) ? 1 : 0)
        }
        // Words no other note has carry no evidence either way.
        let seen = tokens.filter { frequency($0) > 0 }
        guard !seen.isEmpty else { return [] }
        let total = Double(otherCount)
        func idf(_ token: String) -> Double {
            log((total + 1) / (Double(frequency(token)) + 1)) + 1
        }
        let weightSum = seen.reduce(0) { $0 + idf($1) }
        let ownFolder = ownEntry?.folder
        return folderSizes.keys.compactMap { folder -> SimilarityScore? in
            let isOwn = ownFolder == folder
            let size = Double((folderSizes[folder] ?? 0) - (isOwn ? 1 : 0))
            guard size > 0, let counts = folderTokenCounts[folder] else { return nil }
            var score = 0.0
            var matched = 0
            for token in seen {
                let inFolder = Double((counts[token] ?? 0) - (isOwn && own.contains(token) ? 1 : 0))
                guard inFolder > 0 else { continue }
                let coverage = inFolder / size
                // How much of the word's use across the library is in this
                // folder. "Review" in every folder is no evidence for one.
                let specificity = inFolder / Double(frequency(token))
                score += idf(token) * coverage * specificity
                if coverage >= 0.5 { matched += 1 }
            }
            guard score > 0 else { return nil }
            let supporting = (byFolder[folder] ?? []).filter {
                $0.id != note.id && !$0.tokens.isDisjoint(with: seen)
            }.count
            return SimilarityScore(
                folder: folder, score: score / weightSum,
                matchedTokens: matched, supportingNotes: supporting
            )
        }
        .sorted { $0.score > $1.score || ($0.score == $1.score && $0.folder < $1.folder) }
    }

    private func similaritySuggestion(for note: MeetingNote) -> FolderSuggestion? {
        let tokens = FolderSuggester.tokens(in: note.title)
        let scores = similarityScores(for: note)
        guard let best = scores.first,
              best.score >= Self.similarityFloor,
              best.supportingNotes >= Self.minimumSupportingNotes,
              best.matchedTokens >= 2,
              best.matchedTokens * 2 >= tokens.count
        else { return nil }
        if scores.count > 1, best.score - scores[1].score < Self.similarityMargin { return nil }
        return FolderSuggestion(
            folder: best.folder,
            reason: "Similar to \(best.supportingNotes) notes there",
            signal: .similarity
        )
    }

    // MARK: - Auto-filing

    /// The folder a newly recorded meeting should be filed in without asking,
    /// or nil when it should only be suggested (or left alone).
    ///
    /// Only recurring meetings are filed. A meeting recurs when the calendar
    /// says so, or when at least two earlier sittings share its series key;
    /// either way at least one of them must already be filed. The earlier
    /// sittings must agree: all filed ones in one folder, or three quarters
    /// with the most recent filed sitting among them. And the most recent
    /// earlier sitting must itself be in that folder, so a series the person
    /// has stopped filing (or just moved back out) is not filed again.
    func autoFilingFolder(for note: MeetingNote, calendarSaysRecurring: Bool) -> String? {
        guard note.kind == .meeting, !folders.isEmpty else { return nil }
        let key = FolderSuggester.seriesKey(for: note.title)
        guard !key.isEmpty else { return nil }
        let sittings = (bySeries[key] ?? []).filter { $0.id != note.id }
        let filed = sittings.filter { $0.folder != nil }
        guard !filed.isEmpty, calendarSaysRecurring || sittings.count >= 2 else { return nil }
        let counts = Dictionary(grouping: filed, by: { $0.folder! }).mapValues(\.count)
        guard let top = counts.max(by: { $0.value < $1.value }) else { return nil }
        let latestFiled = filed.max { $0.startedAt < $1.startedAt }
        let consistent = counts.count == 1
            || (Double(top.value) / Double(filed.count) >= 0.75 && latestFiled?.folder == top.key)
        guard consistent else { return nil }
        guard let latest = sittings.max(by: { $0.startedAt < $1.startedAt }),
              latest.folder == top.key else { return nil }
        return top.key
    }
}

/// The words of a folder's name that must appear for the name signal.
struct FolderNameKey: Hashable, Sendable {
    let required: Set<String>
    /// How the name is written in the folder, for the reason line.
    let display: String

    /// Nil when nothing distinctive is left, as in "Notes" or "2024".
    init?(folderName: String) {
        let words = FolderSuggester.words(in: folderName)
        // A possessive names an owner: "Massimo’s ramblings" is about
        // Massimo, and a meeting with Massimo belongs there even when it
        // rambles about nothing.
        if let owner = words.first(where: \.isPossessive),
           let token = FolderSuggester.normalizedToken(owner.text) {
            required = [token]
            display = owner.text
            return
        }
        var tokens: Set<String> = []
        var shown: [String] = []
        for word in words {
            guard let token = FolderSuggester.normalizedToken(word.text),
                  !FolderSuggester.genericFolderWords.contains(token) else { continue }
            tokens.insert(token)
            shown.append(word.text)
        }
        guard !tokens.isEmpty else { return nil }
        required = tokens
        display = shown.joined(separator: " ")
    }
}

enum FolderSuggester {
    struct Word: Hashable {
        let text: String
        let isPossessive: Bool
    }

    /// Words that say nothing about what a note is about.
    static let stopWords: Set<String> = [
        "the", "a", "an", "of", "for", "and", "or", "with", "to", "at", "in",
        "on", "by", "about", "from", "into", "our", "my", "your", "vs", "via",
        "am", "pm", "re", "fw", "fwd",
    ]

    /// Words too common in meeting titles and folder names to identify either.
    static let genericFolderWords: Set<String> = [
        "meeting", "call", "note", "chat", "untitled", "recording", "misc",
        "miscellaneous", "other", "archive", "general", "inbox", "stuff",
        "thing", "sync", "catchup", "catch", "up", "one", "weekly", "daily",
        "monthly", "old", "new",
    ]

    /// Titles made only of these are placeholders, not a series. "Sync" is
    /// deliberately absent: "Weekly sync" is a real series.
    static let placeholderSeriesWords: Set<String> = [
        "meeting", "meetings", "call", "note", "notes", "chat", "untitled",
        "recording", "new", "zoom", "teams", "google", "meet", "facetime",
        "webex", "browser", "manual",
    ]

    /// Series key as prep uses it, minus placeholder titles: every
    /// "Meeting Thu 7:34 PM" would otherwise be one enormous series.
    static func seriesKey(for title: String) -> String {
        guard !MeetingTitleGenerator.isFallbackTitle(title, fallbackTitle: "") else { return "" }
        let key = SeriesMatcher.seriesKey(for: title)
        let words = key.split(separator: " ").map(String.init)
        guard words.contains(where: { !placeholderSeriesWords.contains($0) }) else { return "" }
        return key
    }

    /// Splits text into words, noting possessives ("Massimo’s", "James'").
    static func words(in text: String) -> [Word] {
        let normalized = text.replacingOccurrences(of: "’", with: "'")
        var result: [Word] = []
        for raw in normalized.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'") }) {
            var word = String(raw)
            var possessive = false
            let lower = word.lowercased()
            if lower.hasSuffix("'s") {
                word = String(word.dropLast(2))
                possessive = true
            } else if word.hasSuffix("'"), word.count > 1 {
                word = String(word.dropLast())
                possessive = true
            }
            word = word.replacingOccurrences(of: "'", with: "")
            guard !word.isEmpty else { continue }
            result.append(Word(text: word, isPossessive: possessive))
        }
        return result
    }

    /// Lowercased, singular-ish, and nil for numbers, stop words and
    /// fragments too short to identify anything.
    static func normalizedToken(_ word: String) -> String? {
        let lower = word.lowercased()
        guard lower.count >= 2, !lower.allSatisfy(\.isNumber), !stopWords.contains(lower) else {
            return nil
        }
        return stem(lower)
    }

    /// Plural and singular read the same: "reviews" matches "review".
    static func stem(_ word: String) -> String {
        if word.count > 4, word.hasSuffix("ies") { return String(word.dropLast(3)) + "y" }
        if word.count > 3, word.hasSuffix("s"), !word.hasSuffix("ss"), !word.hasSuffix("us") {
            return String(word.dropLast())
        }
        return word
    }

    /// Every normalized token, for matching folder names.
    static func nameTokens(in text: String) -> Set<String> {
        Set(words(in: text).compactMap { normalizedToken($0.text) })
    }

    /// Tokens used for similarity: names plus content words, minus the ones
    /// every meeting title shares and the dates series matching drops.
    static func tokens(in title: String) -> Set<String> {
        let dateWords: Set<String> = [
            "week", "month", "year", "today", "tomorrow", "monday", "tuesday",
            "wednesday", "thursday", "friday", "saturday", "sunday", "mon", "tue",
            "wed", "thu", "fri", "sat", "sun", "january", "february", "march",
            "april", "may", "june", "july", "august", "september", "october",
            "november", "december", "jan", "feb", "mar", "apr", "jun", "jul",
            "aug", "sep", "sept", "oct", "nov", "dec",
        ]
        return nameTokens(in: title).filter {
            $0.count >= 3 && !genericFolderWords.contains($0) && !dateWords.contains($0)
        }
    }
}
