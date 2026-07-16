import SwiftUI
import AppKit

@main
struct GPConnectApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // WindowManager opens SettingsView as a plain NSWindow (see MenuBarView's
    // "Settings..." button) — the SwiftUI Settings scene's showSettingsWindow:
    // action isn't reliably wired up in this NSApplicationDelegateAdaptor app,
    // same class of issue as the SAML/IP-ranges windows (see GPConnect/CLAUDE.md).
    // This empty scene only exists to satisfy `App`'s Scene requirement.
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    let vpnManager = VPNManager()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var spinTimer: Timer?
    private var spinBaseImage: NSImage?
    private var spinAngle: CGFloat = 0
    private var durationTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeading
        updateIcon()

        popover = NSPopover()
        popover.contentSize = NSSize(width: 320, height: 420)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: MenuBarView().environmentObject(vpnManager)
        )

        if let button = statusItem.button {
            button.action = #selector(togglePopover)
            button.target = self
        }

        vpnManager.onStatusChange = { [weak self] in
            self?.updateIcon()
        }

        promptToInstallHelperIfNeeded()
    }

    private func promptToInstallHelperIfNeeded() {
        guard !HelperInstaller.isInstalled else { return }

        let alert = NSAlert()
        alert.messageText = "Install Privileged Helper?"
        alert.informativeText = "GPConnect needs a small helper daemon to run openconnect as root without " +
            "prompting for your password every time. This requires your admin password once, now."
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        Task {
            do {
                try await HelperInstaller.install()
            } catch {
                let failure = NSAlert()
                failure.alertStyle = .warning
                failure.messageText = "Helper Install Failed"
                failure.informativeText = error.localizedDescription
                failure.runModal()
            }
        }
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        if vpnManager.isTransitional {
            startSpinning()
        } else {
            stopSpinning()
            button.image = statusImage()
        }

        if vpnManager.status == .connected {
            startDurationTimer()
        } else {
            stopDurationTimer()
            button.title = ""
        }
    }

    private func statusImage() -> NSImage? {
        guard let base = NSImage(systemSymbolName: vpnManager.statusIcon, accessibilityDescription: "VPN Status") else {
            return nil
        }
        guard vpnManager.shouldTintIconRed else { return base }
        let redConfig = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
        let redImage = base.withSymbolConfiguration(redConfig) ?? base
        redImage.isTemplate = false
        return redImage
    }

    private func startDurationTimer() {
        updateDurationLabel()
        guard durationTimer == nil else { return }
        durationTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateDurationLabel()
            }
        }
        RunLoop.main.add(durationTimer!, forMode: .common)
    }

    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
    }

    private func updateDurationLabel() {
        guard let since = vpnManager.connectedSince else {
            statusItem.button?.title = ""
            return
        }
        let elapsed = Int(Date().timeIntervalSince(since))
        let h = elapsed / 3600
        let m = (elapsed % 3600) / 60
        statusItem.button?.title = h > 0 ? " \(h)h \(m)m" : " \(m)m"
    }

    private func startSpinning() {
        guard spinTimer == nil else { return }
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        guard let base = NSImage(systemSymbolName: vpnManager.statusIcon, accessibilityDescription: "VPN Status")?
            .withSymbolConfiguration(config) else { return }
        spinBaseImage = base
        spinAngle = 0
        spinTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let base = self.spinBaseImage else { return }
                self.spinAngle -= 12
                if self.spinAngle <= -360 { self.spinAngle += 360 }
                self.statusItem.button?.image = self.rotatedImage(base, degrees: self.spinAngle)
            }
        }
        RunLoop.main.add(spinTimer!, forMode: .common)
    }

    private func stopSpinning() {
        spinTimer?.invalidate()
        spinTimer = nil
        spinBaseImage = nil
    }

    private func rotatedImage(_ image: NSImage, degrees: CGFloat) -> NSImage {
        let size = image.size
        let rotated = NSImage(size: size)
        rotated.lockFocus()
        let transform = NSAffineTransform()
        transform.translateX(by: size.width / 2, yBy: size.height / 2)
        transform.rotate(byDegrees: degrees)
        transform.translateX(by: -size.width / 2, yBy: -size.height / 2)
        transform.concat()
        image.draw(at: .zero, from: NSRect(origin: .zero, size: size), operation: .sourceOver, fraction: 1.0)
        rotated.unlockFocus()
        rotated.isTemplate = true
        return rotated
    }

    @objc private func togglePopover() {
        if vpnManager.status == .authenticating {
            WindowManager.shared.openSAMLAuth(vpnManager: vpnManager)
            return
        }
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
