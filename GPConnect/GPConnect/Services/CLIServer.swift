import Foundation

/// Local IPC for the `gpconnect` CLI: one JSON line in (`{"command":"login"}`),
/// one JSON line out (auth result, without starting the tunnel). Socket sits in the
/// app's Application Support directory with 0600 permissions, so only this user
/// can talk to it.
final class CLIServer {
    static let shared = CLIServer()

    nonisolated(unsafe) private var vpnManager: VPNManager?
    nonisolated(unsafe) private var listenFD: Int32 = -1
    nonisolated(unsafe) private var acceptSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "com.perdos.gpconnect.cli-server")

    static var socketPath: String {
        VPNConfig.configURL.deletingLastPathComponent().appendingPathComponent("cli.sock").path
    }

    @MainActor
    func start(vpnManager: VPNManager) {
        guard listenFD < 0 else { return }
        self.vpnManager = vpnManager

        let path = Self.socketPath
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            path.withCString { memcpy(raw.baseAddress!, $0, strlen($0) + 1) }
        }
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 4) == 0 else {
            close(fd)
            return
        }
        chmod(path, S_IRUSR | S_IWUSR)
        listenFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptClient() }
        source.resume()
        acceptSource = source
    }

    @MainActor
    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        unlink(Self.socketPath)
    }

    private func acceptClient() {
        let client = accept(listenFD, nil, nil)
        guard client >= 0 else { return }
        queue.async { [weak self] in self?.serve(client: client) }
    }

    private func serve(client: Int32) {
        defer { close(client) }
        var chunk = [UInt8](repeating: 0, count: 4096)
        var incoming = Data()
        while !incoming.contains(0x0A) {
            let n = read(client, &chunk, chunk.count)
            if n <= 0 { return }
            incoming.append(contentsOf: chunk[0..<n])
        }

        guard let request = (try? JSONSerialization.jsonObject(with: incoming)) as? [String: Any] else {
            reply(client, ["ok": false, "error": "malformed request"])
            return
        }
        guard (request["command"] as? String) == "login" else {
            reply(client, ["ok": false, "error": "unknown command; supported: login"])
            return
        }

        let box = ReplyBox()
        let semaphore = DispatchSemaphore(value: 0)
        let manager = vpnManager
        Task { @MainActor in
            guard let manager else {
                box.set(["ok": false, "error": "GPConnect is not ready"])
                semaphore.signal()
                return
            }
            manager.authenticateForCLI { outcome in
                switch outcome {
                case .success(let result):
                    box.set([
                        "ok": true,
                        "username": result.username,
                        "cookie": result.cookie,
                        "cookieName": result.cookieName,
                        "server": result.server,
                    ])
                case .failure(let error):
                    box.set(["ok": false, "error": error.localizedDescription])
                }
                semaphore.signal()
            }
        }
        if semaphore.wait(timeout: .now() + 300) == .timedOut {
            reply(client, ["ok": false, "error": "GPConnect did not finish the login within 300s"])
            return
        }
        reply(client, box.value ?? ["ok": false, "error": "no result"])
    }

    private func reply(_ client: Int32, _ payload: [String: Any]) {
        var data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        data.append(0x0A)
        data.withUnsafeBytes { raw in _ = write(client, raw.baseAddress, raw.count) }
    }
}

private final class ReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: Any]?

    var value: [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func set(_ newValue: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        stored = newValue
    }
}
