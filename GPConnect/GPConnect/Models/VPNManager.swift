import Foundation
import SwiftUI
import Combine

enum VPNStatus: String {
    case disconnected
    case connecting
    case authenticating
    case connected
    case disconnecting
    case error
}

@MainActor
class VPNManager: ObservableObject {
    @Published var status: VPNStatus = .disconnected {
        didSet { onStatusChange?() }
    }
    @Published var config: VPNConfig
    @Published var connectionLog: [String] = []
    @Published var connectedSince: Date?
    @Published var errorMessage: String?
    @Published var showAuthWindow = false

    var onStatusChange: (() -> Void)?
    private var helperConnection: HelperDaemonConnection?
    private var samlResult: SAMLResult?
    private var tunnelPollTask: Task<Void, Never>?
    private var preExistingTunnels: Set<String> = []

    var statusIcon: String {
        switch status {
        case .disconnected: return "shield.slash"
        case .connecting, .authenticating, .disconnecting: return "arrow.triangle.2.circlepath"
        case .connected: return "checkmark.shield.fill"
        case .error: return "exclamationmark.shield.fill"
        }
    }

    var isTransitional: Bool {
        switch status {
        case .connecting, .authenticating, .disconnecting: return true
        default: return false
        }
    }

    var statusText: String {
        switch status {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting..."
        case .authenticating: return "Authenticating..."
        case .connected:
            if let since = connectedSince {
                let elapsed = Int(Date().timeIntervalSince(since))
                let h = elapsed / 3600
                let m = (elapsed % 3600) / 60
                return "Connected (\(h)h \(m)m)"
            }
            return "Connected"
        case .disconnecting: return "Disconnecting..."
        case .error: return errorMessage ?? "Error"
        }
    }

    var enabledRanges: [IPRange] {
        config.ipRanges.filter(\.enabled)
    }

    var vpnSliceArgs: String {
        enabledRanges.map(\.cidr).joined(separator: " ")
    }

    init() {
        self.config = VPNConfig.load()
    }

    func connect() {
        guard status == .disconnected || status == .error else { return }
        status = .authenticating
        errorMessage = nil
        connectionLog = []
        showAuthWindow = true
    }

    func onSAMLComplete(_ result: SAMLResult) {
        self.samlResult = result
        showAuthWindow = false
        status = .connecting
        appendLog("SAML auth complete for \(result.username)")
        startOpenConnect(result: result)
    }

    func onSAMLFailed(_ error: String) {
        showAuthWindow = false
        status = .error
        errorMessage = error
        appendLog("SAML auth failed: \(error)")
    }

    func disconnect() {
        guard status == .connected || status == .connecting else { return }
        status = .disconnecting
        tunnelPollTask?.cancel()
        tunnelPollTask = nil
        let conn = helperConnection
        helperConnection = nil
        Task { await conn?.disconnect() }
        status = .disconnected
        connectedSince = nil
        appendLog("Disconnected")
    }

    func saveConfig() {
        try? config.save()
    }

    private func startOpenConnect(result: SAMLResult) {
        let sliceArg = vpnSliceArgs
        var args = [
            "--protocol=gp",
            "--user=\(result.username)",
            "--os=mac-intel",
            "--usergroup=gateway:\(result.cookieName)",
            "--useragent=\(config.userAgent)",
            "--passwd-on-stdin",
            config.gateway
        ]

        if !sliceArg.isEmpty {
            args.append(contentsOf: ["-s", "vpn-slice \(sliceArg)"])
        }

        appendLog("Connecting to \(config.gateway)...")

        preExistingTunnels = activeUtunInterfacesWithIPv4()

        let connection = HelperDaemonConnection()
        self.helperConnection = connection

        startTunnelPolling()

        Task {
            do {
                try await connection.connect(args: args, cookie: result.cookie) { [weak self] line in
                    Task { @MainActor in
                        self?.appendLog(line)
                        if line.contains("Connected as") || line.contains("ESP tunnel connected") || line.contains("Configured as") {
                            self?.markConnected()
                        }
                    }
                }
                if self.status == .connecting {
                    self.appendLog("openconnect exited before the tunnel came up.")
                    self.status = .error
                    self.errorMessage = "openconnect exited unexpectedly"
                }
            } catch {
                self.status = .error
                self.errorMessage = error.localizedDescription
                self.appendLog("Error: \(error.localizedDescription)")
            }
            self.tunnelPollTask?.cancel()
        }
    }

    private func markConnected() {
        guard status == .connecting else { return }
        status = .connected
        connectedSince = Date()
        tunnelPollTask?.cancel()
    }

    private func startTunnelPolling() {
        tunnelPollTask?.cancel()
        tunnelPollTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(45)
            while !Task.isCancelled {
                if self.status != .connecting { return }
                if Date() > deadline {
                    self.appendLog("Timed out waiting for the VPN tunnel to come up.")
                    return
                }
                let current = activeUtunInterfacesWithIPv4()
                if !current.subtracting(self.preExistingTunnels).isEmpty {
                    self.markConnected()
                    return
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func appendLog(_ message: String) {
        connectionLog.append(message)
        if connectionLog.count > 200 {
            connectionLog.removeFirst()
        }
    }
}

struct SAMLResult {
    let username: String
    let cookie: String
    let cookieName: String
    let server: String
}
