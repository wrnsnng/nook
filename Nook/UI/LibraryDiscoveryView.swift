import SwiftUI

/// Early rows are navigation only. Editing and cross-library actions continue
/// to use the complete store snapshot after it finishes loading.
struct LibraryDiscoverySidebar: View {
    let catalog: LibraryDiscovery.Catalog
    @Binding var selection: LibrarySelection?

    var body: some View {
        List(selection: $selection) {
            Section {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Loading note contents…")
                }
                Text("\(catalog.entries.count) notes found. You can read a note now; search and editing will be available shortly.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                if !catalog.issues.isEmpty {
                    Label("\(catalog.issues.count) files could not be read.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                }
            }
            Section("Your notes") {
                ForEach(catalog.entries) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.metadata.title).font(.body.weight(.medium)).lineLimit(1)
                        Text(entry.metadata.startedAt, format: .dateTime.month().day().hour().minute())
                            .font(.caption).foregroundStyle(.secondary)
                        Text(entry.fileURL.deletingLastPathComponent().lastPathComponent + "/" + entry.fileURL.lastPathComponent)
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(.vertical, 4)
                    .tag(LibrarySelection.note(entry.identity))
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .listStyle(.sidebar)
        .accessibilityLabel("Notes loading, \(catalog.entries.count) notes available to read")
    }
}

struct LibraryDiscoveryPreview: View {
    let entry: LibraryDiscovery.Entry
    let retry: () -> Void
    @State private var note: MeetingNote?
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                ProgressView().controlSize(.small)
                Text("Loading the rest of your library. Editing and search will be available shortly.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding()
            Divider()
            if let note {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        Text(note.title).font(.title).accessibilityAddTraits(.isHeader)
                        if !note.summary.isEmpty { Text(note.summary) }
                        section("Key points", items: note.keyPoints)
                        section("Decisions", items: note.decisions)
                        section("Action items", items: note.actionItems)
                        section("Open questions", items: note.openQuestions)
                        if !note.personalNotes.isEmpty {
                            Text("My notes").font(.headline).accessibilityAddTraits(.isHeader)
                            Text(note.personalNotes)
                        }
                        if !note.transcript.isEmpty {
                            Text("Transcript").font(.headline).accessibilityAddTraits(.isHeader)
                            ForEach(note.transcript) { segment in
                                Text(segment.text).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
                }
            } else if let failure {
                ContentUnavailableView {
                    Label("This note couldn’t be loaded", systemImage: "doc.badge.ellipsis")
                } description: {
                    Text(failure)
                } actions: {
                    Button("Retry Loading Library", action: retry)
                }
            } else {
                ProgressView("Opening note…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: entry) {
            note = nil
            failure = nil
            let worker = Task.detached(priority: .userInitiated) { try LibraryDiscovery.load(entry) }
            do {
                let loaded = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: { worker.cancel() }
                guard !Task.isCancelled else { return }
                note = loaded
            } catch {
                guard !Task.isCancelled else { return }
                failure = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, items: [String]) -> some View {
        if !items.isEmpty {
            // Scope each section's row identities. Offsets repeat between
            // sections and must not collide when a lazy parent flattens them.
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.headline).accessibilityAddTraits(.isHeader)
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in Text(item) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
