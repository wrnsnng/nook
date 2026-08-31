import AppKit
import SwiftUI

/// A copied Markdown UUID must never load an autosaving editor. This surface
/// reads only the selected file and keeps every resolution step explicit.
struct DuplicateNotePreview: View {
    let note: MeetingNote
    let onReloadLibrary: () -> Void
    private let retainedPreview: DuplicateSourcePreview?

    @State private var source: DuplicateSourceState = .loading
    @State private var activeRequest: DuplicateSourceRequest?
    @State private var retryCount = 0
    @State private var showsRetainedDraft = false

    init(
        note: MeetingNote,
        retainedDraftText: String? = nil,
        onReloadLibrary: @escaping () -> Void = {}
    ) {
        self.note = note
        self.onReloadLibrary = onReloadLibrary
        // The editor retains the complete draft. Capture only enough bytes
        // for this preview and its truncation flag, even for a very long edit.
        self.retainedPreview = retainedDraftText.flatMap {
            Self.boundedPreview(from: Data($0.utf8.prefix(100_001)))
        }
    }

    private var request: DuplicateSourceRequest {
        DuplicateSourceRequest(
            identity: note.libraryIdentity,
            revision: note.fileRevision,
            retryCount: retryCount
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(verbatim: note.title.isEmpty ? "Untitled note" : note.title)
                            .font(NookType.title)
                            .textSelection(.enabled)
                        DuplicateFileLocation(fileURL: note.fileURL)
                    }
                    DuplicateNoteWarning()
                    if let retainedPreview {
                        retainedDraftReview(retainedPreview)
                    }
                    sourcePreview
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            .accessibilityLabel("Duplicate note review, read-only")

            Divider()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { finderActions }
                VStack(alignment: .leading, spacing: 12) { finderActions }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .task(id: request) { await loadSource(request) }
    }

    private func retainedDraftReview(_ preview: DuplicateSourcePreview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Your unsaved edits are still held in Nook", systemImage: "doc.badge.clock")
                .font(NookType.sectionTitle)
            Text("The file preview below shows what is saved on disk. You can review your retained edits here. Resolve the shared note ID to return to your editor. This review changes neither file.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("Review retained Markdown edits", isExpanded: $showsRetainedDraft) {
                VStack(alignment: .leading, spacing: 10) {
                    if preview.isPartial {
                        Text("Only the beginning is shown. Nook still holds your complete unsaved edit.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(verbatim: preview.text.isEmpty ? "Your edit intentionally contains no text." : preview.text)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
                        .padding(12)
                        .background(.background, in: RoundedRectangle(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                        }
                        .accessibilityHint("Read-only retained unsaved Markdown edits")
                        .accessibilityIdentifier("duplicateRetainedDraftSource")
                }
                .padding(.top, 8)
            }
            .accessibilityHint("Shows a read-only preview without saving or discarding your edits")
        }
    }

    @ViewBuilder
    private var sourcePreview: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Markdown source")
                .font(NookType.sectionTitle)
                .accessibilityAddTraits(.isHeader)

            // A new selection can render before its task starts. Never show
            // the preceding file's words beneath the new file's name.
            switch activeRequest == request ? source : .loading {
            case .loading:
                ProgressView("Reading this file…")
                    .frame(maxWidth: .infinity, minHeight: 120)
            case .loaded(let preview):
                if preview.isPartial {
                    Text("Only the beginning is shown. The complete source remains in this file on disk.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(verbatim: preview.text.isEmpty ? "This file contains no text." : preview.text)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
                    .padding(12)
                    .background(.background, in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                    }
                    .accessibilityHint("Read-only source from the selected file")
                    .accessibilityIdentifier("duplicateNoteSource")
            case .failed(let message):
                Label {
                    Text(verbatim: message)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "doc.badge.ellipsis")
                }
                .foregroundStyle(.secondary)
                Button("Try Reading Again") { retryCount += 1 }
                    .disabled(note.fileURL == nil)
            }
        }
    }

    @ViewBuilder
    private var finderActions: some View {
        Button("Show in Finder", systemImage: "doc") {
            guard let file = note.fileURL, file.isFileURL else { return }
            NSWorkspace.shared.activateFileViewerSelecting([file])
        }
        .disabled(note.fileURL?.isFileURL != true)
        .accessibilityHint("Reveals this exact file without changing it")

        Button("Open Notes Folder", systemImage: "folder") {
            guard let file = note.fileURL, file.isFileURL else { return }
            NSWorkspace.shared.open(file.deletingLastPathComponent())
        }
        .disabled(note.fileURL?.isFileURL != true)

        Button("Refresh Library", systemImage: "arrow.clockwise") {
            onReloadLibrary()
        }
        .accessibilityHint("Reloads the notes folder after files are moved or changed")
    }

    private func loadSource(_ request: DuplicateSourceRequest) async {
        activeRequest = request
        source = .loading
        let reader = Task.detached(priority: .userInitiated) {
            Self.readSource(request)
        }
        let result = await withTaskCancellationHandler {
            await reader.value
        } onCancel: {
            reader.cancel()
        }
        guard !Task.isCancelled, activeRequest == request else { return }
        source = result
    }

    private nonisolated static func readSource(
        _ request: DuplicateSourceRequest
    ) -> DuplicateSourceState {
        guard let file = request.identity.fileURL, file.isFileURL else {
            return .failed("This note has no file location. Choose another copy from the library.")
        }
        do {
            try Task.checkCancellation()
            let bytes = try DraftRecoveryFiles.readRegularFile(at: file)
            try Task.checkCancellation()
            if let revision = request.revision,
               MeetingNote.contentRevision(bytes) != revision {
                return .failed("This file changed after the library loaded. Refresh the library, or show the file in Finder to inspect it.")
            }

            guard let preview = boundedPreview(from: bytes) else {
                return .failed("This file’s source cannot be displayed as UTF-8 text. Show it in Finder to inspect the original.")
            }
            try Task.checkCancellation()
            return .loaded(preview)
        } catch is CancellationError {
            return .loading
        } catch DraftRecoveryError.fileTooLarge {
            return .failed("This file is larger than the 32 MB preview limit. Show it in Finder to inspect the complete source.")
        } catch {
            return .failed("Nook couldn’t read this file safely. It may have moved or become unavailable. Show its location in Finder to inspect it.")
        }
    }

    private nonisolated static func boundedPreview(from bytes: Data) -> DuplicateSourcePreview? {
        // Trim a split UTF-8 scalar instead of adding a replacement character
        // that is absent from either the retained draft or the saved source.
        let limit = 100_000
        var end = min(bytes.count, limit)
        if end < bytes.count {
            let minimumEnd = max(0, end - 3)
            while end > minimumEnd, bytes[end] & 0xC0 == 0x80 { end -= 1 }
        }
        guard let text = String(data: bytes.prefix(end), encoding: .utf8) else { return nil }
        return DuplicateSourcePreview(text: text, isPartial: end < bytes.count)
    }
}

/// UUID-only links cannot choose between Finder copies. Each button carries
/// the file's full library identity instead of repeating the shared UUID.
struct DuplicateNoteChooser: View {
    let notes: [MeetingNote]
    let onSelect: (LibraryNoteIdentity) -> Void

    var body: some View {
        if notes.isEmpty {
            ContentUnavailableView(
                "These files are no longer in the library",
                systemImage: "doc.questionmark",
                description: Text("Refresh the library or choose another note from the sidebar.")
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    Text("Choose a file to review")
                        .font(NookType.title)
                        .accessibilityAddTraits(.isHeader)
                    DuplicateNoteWarning()
                    ForEach(notes, id: \.libraryIdentity) { note in
                        Button {
                            onSelect(note.libraryIdentity)
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                DuplicateFileLocation(fileURL: note.fileURL)
                                Text(verbatim: note.title.isEmpty ? "Untitled note" : note.title)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.bordered)
                        .disabled(note.fileURL == nil)
                        .accessibilityLabel("Review file: \(note.fileURL?.lastPathComponent ?? "File location unavailable")")
                        .accessibilityValue(note.fileURL?.path ?? "")
                        .accessibilityHint("Opens a read-only preview of this exact file")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            .accessibilityLabel("Choose a duplicate note file")
        }
    }
}

private struct DuplicateNoteWarning: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("These files share one note ID", systemImage: "doc.on.doc")
                .font(NookType.sectionTitle)
                .foregroundStyle(NookPalette.warning)
            Text("Editing and recording are paused for these copies. Move every other copy outside the notes folder to continue using the one you keep here, then refresh the library. Renaming a file does not change its note ID.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(NookPalette.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct DuplicateFileLocation: View {
    let fileURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: fileURL?.lastPathComponent ?? "File location unavailable")
                .font(.callout.weight(.semibold))
            if let fileURL {
                Text(verbatim: fileURL.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct DuplicateSourceRequest: Hashable, Sendable {
    let identity: LibraryNoteIdentity
    let revision: Data?
    let retryCount: Int
}

private struct DuplicateSourcePreview: Sendable {
    let text: String
    let isPartial: Bool
}

private enum DuplicateSourceState: Sendable {
    case loading
    case loaded(DuplicateSourcePreview)
    case failed(String)
}
