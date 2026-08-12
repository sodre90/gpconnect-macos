import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var vpnManager: VPNManager
    @State private var gateway: String = ""
    @State private var userAgent: String = ""
    @State private var launchAtLogin = false
    @State private var helperRunning = HelperInstaller.isInstalled
    @State private var isInstallingHelper = false
    @State private var helperInstallError: String?
    @State private var autoFillCredentials = false
    @State private var savedUsername = ""
    @State private var savedPassword = ""
    @State private var highlightDisconnectedIcon = true
    @State private var notificationsDenied = false
    @State private var notifyOnDisconnect = true
    @State private var autoDisconnectEnabled = false
    @State private var autoDisconnectMinutes = 240
    @State private var connectedReminderEnabled = false
    @State private var connectedReminderMinutes = 240

    var body: some View {
        Form {
            Section("Gateway") {
                TextField("Gateway address", text: $gateway)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit { save() }
            }

            Section("Advanced") {
                TextField("User-Agent", text: $userAgent)
                    .onSubmit { save() }
            }

            Section("Login Autofill") {
                Toggle("Auto-fill and submit login credentials", isOn: $autoFillCredentials)
                if autoFillCredentials {
                    TextField("Username", text: $savedUsername)
                    SecureField("Password", text: $savedPassword)
                    Text("Password is stored in the macOS Keychain. Okta Verify (or other MFA) is still required every time.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                Toggle("Highlight menu bar icon in red when disconnected", isOn: $highlightDisconnectedIcon)
            }

            Section("Notifications") {
                if notificationsDenied {
                    Text("Notifications are turned off for GPConnect in System Settings › Notifications. "
                         + "Auto-disconnect still works, but no alerts will be shown.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Toggle("Notify when the VPN disconnects", isOn: $notifyOnDisconnect)
                    .disabled(notificationsDenied)

                Toggle("Auto-disconnect after a set time", isOn: $autoDisconnectEnabled)
                if autoDisconnectEnabled {
                    HStack {
                        Text("Disconnect after")
                        TextField("", value: $autoDisconnectMinutes, format: .number)
                            .frame(width: 50)
                            .onSubmit { save() }
                        Text("minutes")
                    }
                }

                Toggle("Remind me if I'm still connected", isOn: $connectedReminderEnabled)
                    .disabled(notificationsDenied)
                if connectedReminderEnabled {
                    HStack {
                        Text("Remind after")
                        TextField("", value: $connectedReminderMinutes, format: .number)
                            .frame(width: 50)
                            .onSubmit { save() }
                        Text("minutes")
                    }
                }
            }

            Section("Helper Daemon") {
                HStack {
                    Text("Status:")
                    Text(helperStatus)
                        .foregroundColor(helperRunning ? .green : .red)
                    Spacer()
                    if !helperRunning {
                        Button(isInstallingHelper ? "Installing…" : "Install Helper") {
                            installHelper()
                        }
                        .disabled(isInstallingHelper)
                    }
                }
                if let helperInstallError {
                    Text(helperInstallError)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }

            Section("Config File") {
                HStack {
                    Text(VPNConfig.configURL.path)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.selectFile(
                            VPNConfig.configURL.path,
                            inFileViewerRootedAtPath: VPNConfig.configURL.deletingLastPathComponent().path
                        )
                    }
                }
            }

            HStack {
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 12)
        .frame(minWidth: 650, idealWidth: 650, minHeight: 550, idealHeight: 550)
        .onAppear {
            gateway = vpnManager.config.gateway
            userAgent = vpnManager.config.userAgent
            helperRunning = HelperInstaller.isInstalled
            autoFillCredentials = vpnManager.config.autoFillCredentials ?? false
            savedUsername = vpnManager.config.savedUsername ?? ""
            savedPassword = CredentialStore.loadPassword(account: vpnManager.config.gateway) ?? ""
            highlightDisconnectedIcon = vpnManager.config.highlightDisconnectedIcon ?? true
            notifyOnDisconnect = vpnManager.config.notifyOnDisconnect ?? true
            autoDisconnectEnabled = vpnManager.config.autoDisconnectEnabled ?? false
            autoDisconnectMinutes = vpnManager.config.autoDisconnectMinutes ?? 240
            connectedReminderEnabled = vpnManager.config.connectedReminderEnabled ?? false
            connectedReminderMinutes = vpnManager.config.connectedReminderMinutes ?? 240
        }
        .task {
            notificationsDenied = await NotificationManager.shared.authorizationDenied()
        }
    }

    private var helperStatus: String {
        helperRunning ? "Running" : "Not Running"
    }

    private func installHelper() {
        isInstallingHelper = true
        helperInstallError = nil
        Task {
            do {
                try await HelperInstaller.install()
                helperRunning = HelperInstaller.isInstalled
            } catch {
                helperInstallError = error.localizedDescription
            }
            isInstallingHelper = false
        }
    }

    private func clampMinutes(_ minutes: Int) -> Int {
        min(max(1, minutes), VPNManager.maxScheduleMinutes)
    }

    private func save() {
        vpnManager.config.gateway = gateway
        vpnManager.config.userAgent = userAgent
        vpnManager.config.autoFillCredentials = autoFillCredentials
        vpnManager.config.savedUsername = autoFillCredentials ? savedUsername : nil
        vpnManager.config.highlightDisconnectedIcon = highlightDisconnectedIcon
        vpnManager.config.notifyOnDisconnect = notifyOnDisconnect
        vpnManager.config.autoDisconnectEnabled = autoDisconnectEnabled
        vpnManager.config.autoDisconnectMinutes = clampMinutes(autoDisconnectMinutes)
        vpnManager.config.connectedReminderEnabled = connectedReminderEnabled
        vpnManager.config.connectedReminderMinutes = clampMinutes(connectedReminderMinutes)
        if autoFillCredentials && !savedPassword.isEmpty {
            CredentialStore.savePassword(savedPassword, account: gateway)
        } else {
            CredentialStore.deletePassword(account: gateway)
        }
        vpnManager.saveConfig()
    }
}
