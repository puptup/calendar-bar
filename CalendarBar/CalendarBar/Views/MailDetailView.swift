import SwiftUI

struct MailDetailView: View {
    @ObservedObject private var mail = MailSyncService.shared
    let thread: MailThread
    var onClose: () -> Void
    @State private var composeMode: MailComposeMode?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(thread.messages) { message in
                        messageCard(message)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxHeight: .infinity)
        .sheet(item: $composeMode) { mode in
            MailComposeView(mode: mode, message: mail.selectedMessage ?? thread.latestMessage)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(thread.subject)
                    .font(.headline)
                    .lineLimit(2)
                if thread.unreadCount > 0 {
                    Text("\(thread.unreadCount) непрочит.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(16)
    }

    private func messageCard(_ message: MailMessage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: { mail.selectedMessageId = message.id }) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(message.from?.displayName ?? "Без отправителя")
                            .font(.subheadline.weight(message.isRead ? .semibold : .bold))
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(message.receivedText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let from = message.from?.email, !from.isEmpty {
                        Text(from)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)

            LinkDetectingText(text: message.displayBodyText)
                .task {
                    await mail.fetchFullBodyIfNeeded(for: message)
                }

            if !message.attachments.isEmpty {
                attachmentsSection(message.attachments)
            }

            actionBar(message)
        }
        .padding(12)
        .background(mail.selectedMessageId == message.id ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func attachmentsSection(_ attachments: [MailAttachment]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Вложения", systemImage: "paperclip")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(attachments) { attachment in
                Button(action: { Task { await mail.download(attachment) } }) {
                    HStack {
                        Image(systemName: "doc")
                        Text(attachment.displayName)
                            .lineLimit(1)
                        Spacer()
                        if !attachment.sizeText.isEmpty {
                            Text(attachment.sizeText)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func actionBar(_ message: MailMessage) -> some View {
        HStack(spacing: 8) {
            Button(message.isRead ? "Непрочитано" : "Прочитано") {
                Task { await mail.setRead(message, read: !message.isRead) }
            }

            Button("Ответить") {
                mail.selectedMessageId = message.id
                composeMode = .reply
            }

            Button("Всем") {
                mail.selectedMessageId = message.id
                composeMode = .replyAll
            }

            Button("Переслать") {
                mail.selectedMessageId = message.id
                composeMode = .forward
            }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .font(.caption)
    }
}
