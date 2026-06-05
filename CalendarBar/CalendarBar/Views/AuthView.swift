import SwiftUI
import AppKit

struct AuthView: View {
    @ObservedObject private var store = SettingsStore.shared
    @State private var email = ""
    @State private var server = AccountSettings.defaultServer
    @State private var domain = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            fields
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }
            actionButtons
            quitButton
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.clear)
        .onAppear(perform: applyStoredValues)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Учётная запись Exchange")
                .font(.headline)
            Text("Настройка как в Календаре iPhone")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var fields: some View {
        VStack(spacing: 10) {
            authField(label: "Email", text: $email, placeholder: "name@organization.com")
            authField(label: "Сервер", text: $server, placeholder: "owa.organization.com")
            authField(label: "Домен", text: $domain, placeholder: "domen")
            authField(label: "Имя пользователя", text: $username, placeholder: "u_*****")
            authSecureField(label: "Пароль", text: $password)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func authField(label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func authSecureField(label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            SecureField("Пароль", text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var actionButtons: some View {
        HStack {
            Spacer()
            Button("Отмена") {
                password = ""
                errorMessage = nil
            }
            .keyboardShortcut(.cancelAction)

            Button(action: signIn) {
                if isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Войти")
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(isLoading)
        }
        .padding(16)
    }

    private var quitButton: some View {
        HStack {
            Button("Закрыть CalendarBar") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
            .keyboardShortcut("q", modifiers: .command)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private func applyStoredValues() {
        email = store.account.email
        server = store.account.server.isEmpty ? AccountSettings.defaultServer : store.account.server
        domain = store.account.domain
        username = store.account.username
        password = store.password ?? ""
    }

    private func signIn() {
        errorMessage = nil

        let trimmedEmail = email.trimmingCharacters(in: .whitespaces)
        let trimmedServer = server.trimmingCharacters(in: .whitespaces)
        let trimmedDomain = domain.trimmingCharacters(in: .whitespaces)
        let trimmedUsername = username.trimmingCharacters(in: .whitespaces)

        guard !trimmedEmail.isEmpty else {
            errorMessage = "Укажите email"
            return
        }
        guard !trimmedServer.isEmpty else {
            errorMessage = "Укажите сервер"
            return
        }
        guard !password.isEmpty else {
            errorMessage = "Укажите пароль"
            return
        }

        let resolvedUsername = trimmedUsername.isEmpty ? trimmedEmail : trimmedUsername

        isLoading = true

        Task {
            do {
                let deviceId = store.account.deviceId.isEmpty
                    ? AccountSettings.generateDeviceId()
                    : store.account.resolvedDeviceId
                let settings = AccountSettings(
                    email: trimmedEmail,
                    server: trimmedServer,
                    domain: trimmedDomain,
                    username: resolvedUsername,
                    deviceId: deviceId
                )
                let client = ExchangeClient(settings: settings, password: password)
                try await client.testConnection()

                try store.saveCredentials(
                    email: settings.email,
                    server: settings.server,
                    domain: settings.domain,
                    username: settings.username,
                    password: password
                )
                store.account.deviceId = client.deviceId
                await NotificationService.shared.requestAuthorization()
                await CalendarSyncService.shared.syncNow()
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }
}
