import SwiftUI
import AppKit

@main
struct GPConnectApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(appDelegate.vpnManager)
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
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
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        if vpnManager.isTransitional {
            startSpinning()
        } else {
            stopSpinning()
            button.image = NSImage(
                systemSymbolName: vpnManager.statusIcon,
                accessibilityDescription: "VPN Status"
            )
        }
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
