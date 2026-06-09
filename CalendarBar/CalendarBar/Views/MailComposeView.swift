import SwiftUI

enum MailComposeMode: String, Identifiable {
    case newMessage
    case reply
    case replyAll
    case forward

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newMessage: return "Новое письмо"
        case .reply: return "Ответить"
        case .replyAll: return "Ответить всем"
        case .forward: return "Переслать"
        }
    }
}

struct MailComposeView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var mail = MailSyncService.shared
    let mode: MailComposeMode
    let message: MailMessage?

    @State private var to = ""
    @State private var cc = ""
    @State private var subject = ""
    @State private var draftBody = ""
    @State private var sending = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(mode.title)
                    .font(.headline)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
            }

            if mode == .newMessage || mode == .forward {
                field("Кому", text: $to)
            }
            if mode == .newMessage {
                field("Копия", text: $cc)
                field("Тема", text: $subject)
            }

            TextEditor(text: $draftBody)
                .font(.body)
                .frame(width: 420, height: 180)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                )

            if let error = mail.actionError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            HStack {
                Spacer()
                Button("Отмена") { dismiss() }
                Button(sending ? "Отправляем…" : "Отправить") {
                    Task { await send() }
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(sending || draftBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || missingRecipients)
            }
        }
        .padding(18)
        .frame(width: 460)
        .onAppear(perform: prefill)
    }

    private var missingRecipients: Bool {
        (mode == .newMessage || mode == .forward) && to.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func field(_ label: String, text: Binding<String>) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)
            TextField(label, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func prefill() {
        guard let message else { return }
        switch mode {
        case .newMessage:
            break
        case .reply, .replyAll:
            subject = message.displaySubject
        case .forward:
            subject = message.displaySubject
            draftBody = "\n\n--- Пересылаемое сообщение ---\n\(message.displayBodyText)"
        }
    }

    private func send() async {
        sending = true
        defer { sending = false }

        switch mode {
        case .newMessage:
            await mail.send(to: to, cc: cc, subject: subject, body: draftBody)
        case .reply:
            if let message {
                await mail.reply(to: message, body: draftBody, replyAll: false)
            }
        case .replyAll:
            if let message {
                await mail.reply(to: message, body: draftBody, replyAll: true)
            }
        case .forward:
            if let message {
                await mail.forward(message: message, to: to, body: draftBody)
            }
        }

        if mail.actionError == nil {
            dismiss()
        }
    }
}
