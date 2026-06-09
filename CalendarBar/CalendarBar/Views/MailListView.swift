import SwiftUI
import AppKit

struct MailListView: View {
    @ObservedObject private var mail = MailSyncService.shared
    @ObservedObject private var store = SettingsStore.shared
    @State private var selectedThreadId: String?
    @State private var composingNewMessage = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            folderTabs
            Divider()
            if mail.threads.isEmpty {
                emptyState
            } else {
                HStack(alignment: .top, spacing: 0) {
                    threadList
                        .frame(width: MailPopoverMetrics.listWidth)

                    if let selectedThread {
                        Divider()
                        MailDetailView(thread: selectedThread, onClose: {
                            selectedThreadId = nil
                            mail.selectedMessageId = nil
                        })
                        .frame(width: MailPopoverMetrics.detailWidth)
                        .transaction { $0.animation = nil }
                    }
                }
                .frame(maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .frame(width: panelWidth, height: MailPopoverMetrics.height)
        .background(Color.clear)
        .sheet(isPresented: $composingNewMessage) {
            MailComposeView(mode: .newMessage, message: nil)
        }
        .animation(.easeInOut(duration: 0.2), value: selectedThreadId != nil)
        .onAppear {
            syncSelectedThreadFromService()
            updatePopoverSize()
        }
        .onChange(of: selectedThreadId != nil) { _, _ in updatePopoverSize() }
        .onChange(of: mail.selectedMessageId) { _, _ in
            syncSelectedThreadFromService()
        }
        .onChange(of: mail.threads.count) { _, _ in
            syncSelectedThreadFromService()
            if let selectedThreadId, !mail.threads.contains(where: { $0.id == selectedThreadId }) {
                self.selectedThreadId = nil
                mail.selectedMessageId = nil
            }
        }
    }

    private var panelWidth: CGFloat {
        MailPopoverMetrics.totalWidth(showingDetail: selectedThreadId != nil)
    }

    private var selectedThread: MailThread? {
        guard let selectedThreadId else { return nil }
        return mail.threads.first { $0.id == selectedThreadId }
    }

    private var toolbar: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(store.account.email.isEmpty ? "Почта" : store.account.email)
                    .font(.headline)
                    .lineLimit(1)
                Text(mail.syncState.statusText)
                    .font(.caption)
                    .foregroundStyle(mail.syncState.isError ? .red : .secondary)
            }

            Spacer()

            Button(action: { composingNewMessage = true }) {
                Image(systemName: "square.and.pencil")
                    .font(.caption.weight(.semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Новое письмо")

            Button(action: { Task { await mail.syncNow() } }) {
                Image(systemName: "arrow.clockwise")
                    .font(.caption.weight(.semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Обновить")
            .disabled(mail.syncState == .syncing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var folderTabs: some View {
        HStack(spacing: 6) {
            ForEach(MailFolderKind.allCases) { folder in
                Button(action: { mail.selectFolder(folder) }) {
                    Text(folder.title)
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                        .allowsTightening(true)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity)
                        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                .foregroundStyle(mail.selectedFolder == folder ? .primary : .secondary)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(mail.selectedFolder == folder ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(mail.selectedFolder == folder ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.08), lineWidth: 1)
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var threadList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(mail.threads) { thread in
                    Button(action: {
                        selectedThreadId = thread.id
                        mail.selectedMessageId = thread.latestMessage?.id
                    }) {
                        MailThreadRow(thread: thread, isSelected: selectedThreadId == thread.id)
                    }
                    .buttonStyle(.plain)
                    Divider()
                        .padding(.leading, 16)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "envelope")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(mail.syncState == .syncing ? "Загружаем письма…" : "В папке «\(mail.selectedFolder.title)» пока пусто")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            footerStatus

            Spacer()

            if let error = mail.actionError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var footerStatus: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(mail.unreadCount > 0 ? "Непрочитанных: \(mail.unreadCount)" : "Нет непрочитанных")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func updatePopoverSize() {
        NotificationCenter.default.post(
            name: .mailPopoverSizeChanged,
            object: nil,
            userInfo: ["width": panelWidth, "height": MailPopoverMetrics.height]
        )
    }

    private func syncSelectedThreadFromService() {
        guard let messageId = mail.selectedMessageId,
              let thread = mail.threads.first(where: { thread in
                  thread.messages.contains(where: { $0.id == messageId })
              }) else { return }
        selectedThreadId = thread.id
    }
}

private struct MailThreadRow: View {
    let thread: MailThread
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if thread.unreadCount > 0 {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 7, height: 7)
                }
                Text(thread.subject)
                    .font(.subheadline.weight(thread.unreadCount > 0 ? .bold : .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer()
                Text(thread.latestMessage?.receivedText ?? "")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(thread.latestMessage?.from?.displayName ?? "Без отправителя")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if let preview = thread.latestMessage?.displayBodyText, !preview.isEmpty {
                Text(preview)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
    }
}

private extension SyncState {
    var isError: Bool {
        if case .failure = self { return true }
        return false
    }
}
