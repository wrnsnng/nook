import AppKit
import SwiftUI

/// Visibility only. Recovery and note deletion retain their existing previews
/// and confirmations in the library; no folder-wide cleanup lives here.
struct StorageInventoryView: View {
    let locations: [StorageInventoryLocation]
    let reviewLibrary: @MainActor () -> Void
    @ObservedObject var inventory: StorageInventoryController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Storage on This Mac")
                        .font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text("Review where Nook keeps your data.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)

            Form {
                Section {
                    HStack {
                        if inventory.isScanning {
                            ProgressView().controlSize(.small)
                                .accessibilityLabel("Counting Nook storage file sizes")
                            Text(inventory.phase.label)
                            Spacer()
                            Button("Cancel") { inventory.cancel() }
                        } else {
                            Text(inventory.phase.label)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Refresh") { inventory.refresh(locations) }
                        }
                    }
                } footer: {
                    Text("Only file metadata is counted. Contents are not opened. Sizes are logical file sizes, not space guaranteed to be freed. Files can change while counting.")
                }

                ForEach(inventory.entries) { entry in
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(entry.location.title)
                                    .font(.headline)
                                    .accessibilityAddTraits(.isHeader)
                                Spacer()
                                Text(sizeLabel(entry))
                                    .font(.body.monospacedDigit())
                            }
                            Text(entry.location.detail)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Text(entry.location.url.path(percentEncoded: false))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            ForEach(StorageInventoryEntry.Warning.allCases.filter { entry.warnings.contains($0) }, id: \.self) { warning in
                                Label(warning.rawValue, systemImage: "exclamationmark.triangle")
                                    .font(.caption)
                                    .foregroundStyle(NookPalette.warning)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if entry.fileCount > entry.sampleFiles.count, !entry.sampleFiles.isEmpty {
                                Text("Finder will select \(entry.sampleFiles.count) of these files. Additional files remain in the same folder.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            HStack {
                                if entry.location.canReviewInLibrary {
                                    Button("Review in Library") {
                                        dismiss()
                                        reviewLibrary()
                                    }
                                    .accessibilityLabel("Review \(entry.location.title.lowercased()) in Library")
                                }
                                Button(entry.sampleFiles.isEmpty ? "Show in Finder" : "Show Files in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting(
                                        entry.sampleFiles.isEmpty ? [entry.location.url] : entry.sampleFiles
                                    )
                                }
                                .disabled(entry.status == .missing)
                                .accessibilityLabel("Show \(entry.location.title.lowercased()) location in Finder")
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section {
                    Text("Review individual notes, unfinished recordings, and recovered writing in the Library before deleting them. Recovery copies are never cleared by this overview.")
                    Text("Exports, backups, old notes folders, Trash, and data kept by external CLI tools are not tracked or erased here. Other Nook installations may have their own drafts, caches, and event logs.")
                } header: {
                    Text("What this overview does not include")
                } footer: {
                    Text("Linked files and folders are not followed. Large or unavailable folders may show a partial count. Refresh after reviewing files in Finder or the Library.")
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 620, height: 620)
        .task(id: locations) { inventory.refresh(locations) }
        .onDisappear { inventory.cancel() }
        .onExitCommand { dismiss() }
    }

    private func sizeLabel(_ entry: StorageInventoryEntry) -> String {
        switch entry.status {
        case .missing:
            "Not present"
        case .unavailable:
            "Not counted"
        case .complete, .partial:
            "\(entry.status == .partial ? "Partial: " : "")\(ByteCountFormatter.string(fromByteCount: entry.bytes, countStyle: .file)) · \(entry.fileCount) \(entry.fileCount == 1 ? "file" : "files")"
        }
    }
}
