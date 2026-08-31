import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Recovery is separate from the active editors: showing a checkpoint never
/// loads it into an autosaving controller or changes the selected note.
struct DraftRecoverySection: View {
    @ObservedObject var controller: DraftRecoveryController
    @ObservedObject var journal: DraftJournal
    @State private var selectedDraft: DraftCheckpoint?
    @State private var showsAll = false

    private static let visibleLimit = 3

    @ViewBuilder
    var body: some View {
        if !journal.recoveredDrafts.isEmpty || !journal.issues.isEmpty
            || journal.statusMessage != nil {
            Section {
                ForEach(visibleDrafts) { checkpoint in
                    Button {
                        selectedDraft = checkpoint
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(checkpoint.title.isEmpty ? "Untitled draft" : checkpoint.title)
                                .font(.callout.weight(.medium))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                            Text("\(checkpoint.kind.label) · \(checkpoint.checkpointedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(checkpoint.libraryPath)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Review recovered \(checkpoint.kind.label): \(checkpoint.title.isEmpty ? "Untitled draft" : checkpoint.title)")
                    .accessibilityValue(checkpoint.checkpointedAt.formatted(date: .abbreviated, time: .shortened))
                    .accessibilityHint("Opens a read-only preview. The original note is unchanged.")
                }

                if journal.recoveredDrafts.count > Self.visibleLimit {
                    Button(disclosureLabel) {
                        showsAll.toggle()
                    }
                    .font(.caption)
                }

                ForEach(journal.issues.prefix(Self.visibleLimit)) { issue in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(issue.fileURL.lastPathComponent)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                        Label {
                            Text(issue.message)
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        Button("Show recovery file in Finder") {
                            controller.revealIssue(issue)
                        }
                        .font(.caption)
                        .accessibilityLabel("Show \(issue.fileURL.lastPathComponent) in Finder")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if journal.issues.count > Self.visibleLimit {
                    Text("\(journal.issues.count - Self.visibleLimit) more recovery files need attention. Open the recovery folder to inspect them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let status = journal.statusMessage ?? controller.message {
                    Label {
                        Text(status)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "info.circle")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Retry") { Task { await controller.retry() } }
                        .disabled(controller.isWorking)
                    Button("Open recovery folder") {
                        controller.revealRecoveryDirectory()
                    }
                }
                .font(.caption)
            } header: {
                Label("Recovered drafts", systemImage: "doc.badge.clock")
            } footer: {
                Text("Review unfinished writing from an earlier session. Your existing notes stay unchanged.")
            }
            .sheet(item: $selectedDraft) { checkpoint in
                DraftRecoveryView(checkpoint: checkpoint, controller: controller)
            }
            .task { await controller.reconcileCompletedDrafts() }
        }
    }

    private var visibleDrafts: [DraftCheckpoint] {
        showsAll ? journal.recoveredDrafts
            : Array(journal.recoveredDrafts.prefix(Self.visibleLimit))
    }

    private var disclosureLabel: String {
        guard !showsAll else { return "Show fewer drafts" }
        let remaining = journal.recoveredDrafts.count - visibleDrafts.count
        return "Show \(remaining) more \(remaining == 1 ? "draft" : "drafts")"
    }
}

struct DraftRecoveryView: View {
    let checkpoint: DraftCheckpoint
    @ObservedObject var controller: DraftRecoveryController
    @ObservedObject private var journal: DraftJournal
    @ObservedObject private var store: MarkdownStore
    @Environment(\.dismiss) private var dismiss
    @State private var showsDiscardConfirmation = false
    @State private var panelIsOpen = false
    @State private var errorMessage: String?
    @State private var actionMessage: String?
    @State private var canSave: Bool?
    private let previewText: String
    private let previewIsPartial: Bool

    init(checkpoint: DraftCheckpoint, controller: DraftRecoveryController) {
        self.checkpoint = checkpoint
        self.controller = controller
        self.journal = controller.journal
        self.store = controller.store
        // A large source still exports and saves in full. Bound only its
        // selectable preview so opening recovery cannot render megabytes of
        // text in the sidebar's sheet on the main actor.
        let previewLimit = 100_000
        self.previewIsPartial = checkpoint.text.utf8.count > previewLimit
        self.previewText = String(decoding: checkpoint.text.utf8.prefix(previewLimit), as: UTF8.self)
        self._canSave = State(initialValue: checkpoint.kind == .markdown ? nil : true)
    }

    private var isBusy: Bool { controller.isWorking || panelIsOpen }
    private var isAvailable: Bool { journal.recoveredDrafts.contains { $0.id == checkpoint.id } }
    private var isStale: Bool {
        guard let latest = controller.draft(id: checkpoint.id) else { return false }
        return !DraftRecoveryController.matchesPreview(latest, checkpoint)
    }
    private var destination: URL {
        store.storageURL.standardizedFileURL.resolvingSymlinksInPath()
    }

    var body: some View {
        VStack(spacing: 0) {
            // Long paths and validation messages used to push the only Close
            // and Save controls below a short Mac window. The entire review
            // area now shares one scroll region while actions remain visible.
            GeometryReader { geometry in
                ScrollView {
                    reviewContent
                        .frame(minHeight: max(0, geometry.size.height - 48), alignment: .topLeading)
                        .padding(24)
                }
                .accessibilityLabel("Recovered draft review, read-only")
            }
            Divider()
            recoveryFooter
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
        }
        .frame(minWidth: 590, idealWidth: 680, maxWidth: 840, minHeight: 500, idealHeight: 720)
        .interactiveDismissDisabled(isBusy)
        .task(id: checkpoint.id) {
            guard canSave == nil else { return }
            let source = checkpoint
            let eligible = await Task.detached(priority: .userInitiated) {
                DraftRecoveryController.canSaveAsNewNote(source)
            }.value
            guard !Task.isCancelled else { return }
            canSave = eligible
        }
        .alert("Discard this recovery copy?", isPresented: $showsDiscardConfirmation) {
            Button("Cancel", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
            Button("Move Recovery Copy to Trash", role: .destructive) {
                Task { await discard() }
            }
        } message: {
            Text("Only this unfinished draft copy moves to the Trash. The original note and any new note already saved from this recovery stay unchanged.")
        }
    }

    private var reviewContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            context
            Text(previewText.isEmpty ? "This draft intentionally contains no text." : previewText)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 180, maxHeight: .infinity, alignment: .topLeading)
                .padding(12)
                .background(.background, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                }
                .accessibilityHint("Read-only recovered source")
                .accessibilityIdentifier("recoveredDraftSource")
        }
    }

    private var recoveryFooter: some View {
        VStack(alignment: .leading, spacing: 12) {
            if previewIsPartial {
                Text("Only the beginning is shown. Copy, Export Source, and Save as New Note include the complete draft.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if canSave == false {
                Label("This Markdown source cannot safely receive a new note identity. Copy or export its exact source instead.", systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if canSave == nil {
                ProgressView("Checking Markdown identity…")
                    .controlSize(.small)
            }
            Text("Copy places this text on the system clipboard, where other software may read it. Export Source keeps the exact text in a new .txt file. Both leave this recovery copy in place.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !isAvailable {
                Label("This recovery copy was already saved or removed. Close this preview to return to the library.", systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if isStale {
                Label("This recovery copy changed after its preview opened. Close this window and review the latest copy before continuing.", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(NookPalette.danger)
            } else if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(NookPalette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let actionMessage {
                Label(actionMessage, systemImage: "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            actions
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Recovered draft")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Text(checkpoint.title.isEmpty ? "Untitled draft" : checkpoint.title)
                .font(NookType.title)
                .lineLimit(2)
            Text("Review the checkpoint before choosing what to keep. Closing this window leaves it available for later.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var context: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
            GridRow {
                Text("Editor").foregroundStyle(.secondary)
                Text(checkpoint.kind.label)
            }
            GridRow {
                Text("Checkpoint").foregroundStyle(.secondary)
                Text(checkpoint.checkpointedAt.formatted(date: .abbreviated, time: .shortened))
            }
            GridRow {
                Text("Original library").foregroundStyle(.secondary)
                Text(checkpoint.libraryPath).textSelection(.enabled)
            }
            if let path = checkpoint.originalFilePath {
                GridRow {
                    Text("Original file").foregroundStyle(.secondary)
                    Text(path).textSelection(.enabled)
                }
            }
            GridRow {
                Text("New note destination").foregroundStyle(.secondary)
                Text(destination.path).textSelection(.enabled)
            }
        }
        .font(.caption)
        .lineLimit(2)
        .truncationMode(.middle)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actions: some View {
        let actionsDisabled = isBusy || !isAvailable || isStale
        return VStack(spacing: 12) {
            HStack {
                Button("Copy") { copy() }
                    .disabled(actionsDisabled)
                Button("Export Source…") { Task { await exportSource() } }
                    .disabled(actionsDisabled)
                Spacer()
                Button("Discard Recovery Copy…", role: .destructive) {
                    showsDiscardConfirmation = true
                }
                .disabled(actionsDisabled)
            }
            Divider()
            HStack {
                if controller.isWorking {
                    ProgressView().controlSize(.small)
                    Text("Finishing recovery…").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isBusy)
                Button("Save as New Note") {
                    let displayedDirectory = destination
                    Task { await save(to: displayedDirectory) }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(NookPalette.accent)
                .disabled(actionsDisabled || canSave != true)
                .help("Creates a separate note in the displayed destination. The original is unchanged.")
            }
        }
    }

    private func copy() {
        errorMessage = nil
        do {
            try controller.copy(draftID: checkpoint.id, expectedCheckpoint: checkpoint)
            actionMessage = "Recovered text copied. The recovery copy is still available."
        } catch { errorMessage = error.localizedDescription }
    }

    private func save(to destination: URL) async {
        errorMessage = nil
        actionMessage = nil
        do {
            _ = try await controller.saveAsNewNote(draftID: checkpoint.id, destinationDirectory: destination, expectedCheckpoint: checkpoint)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }

    private func discard() async {
        errorMessage = nil
        actionMessage = nil
        do {
            try await controller.discard(draftID: checkpoint.id, expectedCheckpoint: checkpoint)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }

    private func exportSource() async {
        errorMessage = nil
        actionMessage = nil
        panelIsOpen = true
        defer { panelIsOpen = false }
        let panel = NSSavePanel()
        panel.title = "Export Recovered Source"
        panel.message = "Choose a new file. Existing files are never replaced. The recovery copy stays available in Nook."
        panel.nameFieldStringValue = "Recovered source.txt"
        panel.allowedContentTypes = [.plainText]
        panel.allowsOtherFileTypes = false
        panel.canCreateDirectories = true
        let response = await withCheckedContinuation { continuation in
            panel.begin { response in continuation.resume(returning: response) }
        }
        guard response == .OK, let destination = panel.url else { return }
        do {
            try await controller.exportSource(draftID: checkpoint.id, to: destination, expectedCheckpoint: checkpoint)
            actionMessage = "Exact source exported. The recovery copy is still available."
        } catch { errorMessage = error.localizedDescription }
    }
}
