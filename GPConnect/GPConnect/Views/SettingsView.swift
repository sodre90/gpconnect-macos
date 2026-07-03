import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var vpnManager: VPNManager
    @State private var gateway: String = ""
    @State private var userAgent: String = ""
    @State private var launchAtLogin = false

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

            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
            }

            Section("Helper Daemon") {
                HStack {
                    Text("Status:")
                    Text(helperStatus)
                        .foregroundColor(helperRunning ? .green : .red)
                }
                if !helperRunning {
                    Text("Install with: sudo /path/to/helper/install.sh")
                        .font(.caption)
                        .foregroundColor(.secondary)
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
        }
    }

    private var helperRunning: Bool {
        FileManager.default.fileExists(atPath: "/var/run/openconnect-helper.sock")
    }

    private var helperStatus: String {
        helperRunning ? "Running" : "Not Running"
    }

    private func save() {
        vpnManager.config.gateway = gateway
        vpnManager.config.userAgent = userAgent
        vpnManager.saveConfig()
    }
}
