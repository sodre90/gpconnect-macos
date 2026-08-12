import AppKit
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
    private var connectedTunnelInterfaces: Set<String> = []
    private var autoDisconnectTask: Task<Void, Never>?
    private var connectedReminderTask: Task<Void, Never>?

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

    var shouldTintIconRed: Bool {
        guard config.highlightDisconnectedIcon ?? true else { return false }
        switch status {
        case .disconnected, .error: return true
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

    /// Upper bound on any scheduled duration. Without it, a hand-edited config.json
    /// (the README invites editing it) can overflow the UInt64 nanosecond conversion
    /// in Task.sleep and trap.
    static let maxScheduleMinutes = 10080  // one week

    init() {
        self.config = VPNConfig.load()
        observeSystemWake()
    }

    /// Task.sleep does not advance while the machine is asleep, so a timer armed before
    /// a sleep fires late by roughly the sleep duration. Both schedule methods recompute
    /// from `connectedSince` and handle the already-elapsed case, so re-arming on wake
    /// is enough to correct the drift.
    private func observeSystemWake() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleAutoDisconnectIfEnabled()
                self?.scheduleConnectedReminderIfEnabled()
            }
        }
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
        cancelScheduledNotificationTasks()
        let conn = helperConnection
        helperConnection = nil
        let tunnelsToClear = connectedTunnelInterfaces
        appendLog("Disconnecting...")

        Task {
            await conn?.disconnect()
            await self.confirmDisconnected(expectedGoneInterfaces: tunnelsToClear)
        }
    }

    /// Polls for the tunnel interface(s) to actually go away instead of assuming the
    /// helper tore them down the moment we closed our end of the socket - closing the
    /// socket only asks the daemon to kill openconnect, it doesn't guarantee it happened.
    private func confirmDisconnected(expectedGoneInterfaces: Set<String>) async {
        guard status == .disconnecting else { return }
        let deadline = Date().addingTimeInterval(10)
        while true {
            if activeUtunInterfacesWithIPv4().isDisjoint(with: expectedGoneInterfaces) {
                status = .disconnected
                connectedSince = nil
                connectedTunnelInterfaces = []
                appendLog("Disconnected")
                return
            }
            if Date() > deadline {
                status = .error
                errorMessage = "Failed to fully disconnect; the VPN interface may still be active"
                appendLog("Warning: tunnel interface still present after disconnect request")
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    func saveConfig() {
        try? config.save()
        onStatusChange?()
        if status == .connected {
            scheduleAutoDisconnectIfEnabled()
            scheduleConnectedReminderIfEnabled()
        }
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
                switch self.status {
                case .connecting:
                    self.appendLog("openconnect exited before the tunnel came up.")
                    self.status = .error
                    self.errorMessage = "openconnect exited unexpectedly"
                case .connected:
                    self.appendLog("Connection dropped unexpectedly.")
                    self.status = .error
                    self.errorMessage = "Connection dropped unexpectedly"
                    self.connectedSince = nil
                    self.connectedTunnelInterfaces = []
                    self.helperConnection = nil
                    self.cancelScheduledNotificationTasks()
                    self.notifyDisconnectIfEnabled(body: "Connection dropped unexpectedly.")
                default:
                    break
                }
            } catch {
                if self.status != .disconnected && self.status != .disconnecting {
                    self.status = .error
                    self.errorMessage = error.localizedDescription
                    self.appendLog("Error: \(error.localizedDescription)")
                }
            }
            self.tunnelPollTask?.cancel()
        }
    }

    private func markConnected() {
        guard status == .connecting else { return }
        // Set before `status` so that onStatusChange (fired synchronously by status's
        // didSet) observes a consistent connectedSince rather than nil.
        connectedSince = Date()
        connectedTunnelInterfaces = activeUtunInterfacesWithIPv4().subtracting(preExistingTunnels)
        status = .connected
        tunnelPollTask?.cancel()
        scheduleAutoDisconnectIfEnabled()
        scheduleConnectedReminderIfEnabled()
    }

    /// Reschedules from `connectedSince` (not "now") so calling this again mid-session,
    /// e.g. after Settings are saved, recomputes correctly instead of extending the session.
    private func scheduleAutoDisconnectIfEnabled() {
        autoDisconnectTask?.cancel()
        autoDisconnectTask = nil
        guard status == .connected,
              let connectedSince,
              config.autoDisconnectEnabled ?? false else { return }
        let totalMinutes = min(config.autoDisconnectMinutes ?? 240, Self.maxScheduleMinutes)
        guard totalMinutes > 0 else { return }
        let disconnectAt = connectedSince.addingTimeInterval(Double(totalMinutes) * 60)

        if disconnectAt > Date() {
            autoDisconnectTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(disconnectAt.timeIntervalSinceNow * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.appendLog("Auto-disconnecting after \(totalMinutes) minute(s).")
                self?.notifyDisconnectIfEnabled(body: "VPN auto-disconnected after \(totalMinutes) minute(s).")
                self?.disconnect()
            }
        } else {
            appendLog("Auto-disconnecting (configured duration already elapsed).")
            notifyDisconnectIfEnabled(body: "VPN auto-disconnected after \(totalMinutes) minute(s).")
            disconnect()
        }
    }

    /// Independent of auto-disconnect: there's no way to know a real disconnect time
    /// unless auto-disconnect is also configured, so this just reminds the user they're
    /// still connected after a fixed duration since `connectedSince`.
    private func scheduleConnectedReminderIfEnabled() {
        connectedReminderTask?.cancel()
        connectedReminderTask = nil
        guard status == .connected,
              let connectedSince,
              config.connectedReminderEnabled ?? false else { return }
        let minutes = min(config.connectedReminderMinutes ?? 240, Self.maxScheduleMinutes)
        guard minutes > 0 else { return }
        let fireAt = connectedSince.addingTimeInterval(Double(minutes) * 60)
        guard fireAt > Date() else { return }

        connectedReminderTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(fireAt.timeIntervalSinceNow * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.notify(body: "Still connected to the VPN after \(minutes) minute(s).")
        }
    }

    private func cancelScheduledNotificationTasks() {
        autoDisconnectTask?.cancel()
        autoDisconnectTask = nil
        connectedReminderTask?.cancel()
        connectedReminderTask = nil
    }

    private func notifyDisconnectIfEnabled(body: String) {
        guard config.notifyOnDisconnect ?? true else { return }
        notify(body: body)
    }

    private func notify(body: String) {
        NotificationManager.shared.notify(title: "GPConnect", body: body)
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
