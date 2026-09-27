import AppKit
import SwiftUI

/// Review a recap before it goes anywhere. The draft is editable, Copy puts it
/// on the clipboard, and Open in Mail hands it to a compose window; Nook never
/// sends anything itself.
struct FollowUpDraftView: View {
    let note: MeetingNote

    @Environment(\.dismiss) private var dismiss
    @State private var format: FollowUpDraft.Format = .email
    @State private var subject = ""
    @State private var bodyText = ""
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Draft Follow-up")
                    .font(NookType.sectionTitle)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Picker("Format", selection: $format) {
                    ForEach(FollowUpDraft.Format.allCases) { format in
                        Text(format.label).tag(format)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            if format == .email {
                TextField("Subject", text: $subject)
                    .textFieldStyle(.roundedBorder)
            }

            TextEditor(text: $bodyText)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color(nsColor: .separatorColor))
                }
                .accessibilityLabel("Follow-up text")

            Text("Written from this note on this Mac. Nook never sends it; review it first.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(copied ? "Copied" : "Copy") { copy() }
                if format == .email {
                    Button("Open in Mail") { openInMail() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canCompose)
                        .help(canCompose ? "Open a new message with this text" : "No mail app is set up on this Mac")
                }
            }
        }
        .padding(20)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 440, idealHeight: 520)
        .onAppear(perform: rebuild)
        .onChange(of: format) { _, _ in rebuild() }
    }

    private var canCompose: Bool {
        NSSharingService(named: .composeEmail) != nil
    }

    private func rebuild() {
        let draft = FollowUpDraft.make(from: note, format: format)
        subject = draft.subject
        bodyText = draft.body
        copied = false
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(bodyText, forType: .string)
        copied = true
    }

    private func openInMail() {
        guard let service = NSSharingService(named: .composeEmail) else { return }
        service.subject = subject
        service.perform(withItems: [bodyText])
    }
}
