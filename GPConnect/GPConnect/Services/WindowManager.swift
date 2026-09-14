import AppKit
import SwiftUI

@MainActor
class WindowManager: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = WindowManager()

    private var samlWindow: NSWindow?
    private var rangesWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var logsWindow: NSWindow?
    private var samlLoginActivity: NSObjectProtocol?

    func openSAMLAuth(vpnManager: VPNManager) {
        if let existing = samlWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Keeps the process off App Nap and out of idle sleep while the user is away at
        // their phone; page-level throttling is handled separately, below.
        endSAMLLoginActivity()
        samlLoginActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "Interactive SAML login in progress"
        )

        let view = SAMLAuthView()
            .environmentObject(vpnManager)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 550),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "SAML Login"
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        keepLoginPageRunningWhileUnattended(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.samlWindow = window
    }

    /// The IdP page polls JavaScript while waiting for Okta Verify approval, and WebKit
    /// throttles that polling whenever AppKit reports the window as occluded — so a login
    /// window covered by another window stalls until it is re-foregrounded. Process-level
    /// `beginActivity` does not prevent this; only staying visible does. Floating above other
    /// windows (including full-screen Spaces) keeps the page running while the user looks
    /// away to approve the push on their phone. The window is deliberately not miniaturizable
    /// for the same reason.
    private func keepLoginPageRunningWhileUnattended(_ window: NSWindow) {
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    func closeSAMLAuth() {
        samlWindow?.close()
        samlWindow = nil
        endSAMLLoginActivity()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === samlWindow else { return }
        endSAMLLoginActivity()
    }

    private func endSAMLLoginActivity() {
        if let activity = samlLoginActivity {
            ProcessInfo.processInfo.endActivity(activity)
            samlLoginActivity = nil
        }
    }
}

extension WindowManager {
    func openIPRanges(vpnManager: VPNManager) {
        if let existing = rangesWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = IPRangesEditorView()
            .environmentObject(vpnManager)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 550, height: 500),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "IP Ranges"
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.rangesWindow = window
    }

    func openSettings(vpnManager: VPNManager) {
        if let existing = settingsWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = SettingsView()
            .environmentObject(vpnManager)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 650, height: 550),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.settingsWindow = window
    }

    func openLogs(vpnManager: VPNManager) {
        if let existing = logsWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = LogsView()
            .environmentObject(vpnManager)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Connection Log"
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.logsWindow = window
    }
}
