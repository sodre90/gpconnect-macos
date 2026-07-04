import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var vpnManager: VPNManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusHeader
            Divider().padding(.vertical, 4)
            connectionButton
            Divider().padding(.vertical, 4)
            ipRangesSection
            Divider().padding(.vertical, 4)
            bottomButtons
        }
        .padding(12)
        .frame(width: 320)
        .onChange(of: vpnManager.showAuthWindow) {
            if vpnManager.showAuthWindow {
                vpnManager.showAuthWindow = false
                WindowManager.shared.openSAMLAuth(vpnManager: vpnManager)
            }
        }
    }

    private var statusHeader: some View {
        HStack {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(vpnManager.statusText)
                    .font(.headline)
                if vpnManager.status == .connected {
                    Text(vpnManager.config.gateway)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
        }
    }

    private var statusColor: Color {
        switch vpnManager.status {
        case .connected: return .green
        case .connecting, .authenticating, .disconnecting: return .orange
        case .disconnected: return .gray
        case .error: return .red
        }
    }

    private var connectionButton: some View {
        Group {
            switch vpnManager.status {
            case .disconnected, .error:
                Button("Connect") {
                    vpnManager.connect()
                }
                .buttonStyle(.borderedProminent)
            case .connected:
                Button("Disconnect") {
                    vpnManager.disconnect()
                }
                .buttonStyle(.bordered)
            default:
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var ipRangesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Split Tunnel Ranges")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(vpnManager.enabledRanges.count) active")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(vpnManager.config.ipRanges.prefix(15)) { range in
                        IPRangeRow(range: range)
                    }
                    if vpnManager.config.ipRanges.count > 15 {
                        Text("+ \(vpnManager.config.ipRanges.count - 15) more...")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .frame(maxHeight: 200)
        }
    }

    private var bottomButtons: some View {
        HStack {
            Button("Edit Ranges...") {
                WindowManager.shared.openIPRanges(vpnManager: vpnManager)
            }
            .buttonStyle(.borderless)
            .font(.caption)

            Spacer()

            Button("Logs...") {
                WindowManager.shared.openLogs(vpnManager: vpnManager)
            }
            .buttonStyle(.borderless)
            .font(.caption)

            Button("Settings...") {
                WindowManager.shared.openSettings(vpnManager: vpnManager)
            }
            .buttonStyle(.borderless)
            .font(.caption)

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
    }
}

struct IPRangeRow: View {
    let range: IPRange

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(range.enabled ? .green : .gray)
                .frame(width: 6, height: 6)
            Text(range.cidr)
                .font(.system(.caption, design: .monospaced))
            if !range.label.isEmpty {
                Text(range.label)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
    }
}
