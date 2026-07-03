import Foundation

actor HelperDaemonConnection {
    private static let socketPath = "/var/run/openconnect-helper.sock"
    private var fileHandle: FileHandle?
    private var process: Process?

    func connect(args: [String], cookie: String, onOutput: @escaping @Sendable (String) -> Void) async throws {
        let socket = try createUnixSocket()
        self.fileHandle = socket

        let message: [String: Any] = ["args": args, "cookie": cookie]
        let jsonData = try JSONSerialization.data(withJSONObject: message)
        var payload = jsonData
        payload.append(0x0A) // newline

        socket.write(payload)

        await withCheckedContinuation { continuation in
            socket.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    continuation.resume()
                    return
                }
                if let text = String(data: data, encoding: .utf8) {
                    for line in text.components(separatedBy: .newlines) where !line.isEmpty {
                        onOutput(line)
                    }
                }
            }
        }
    }

    func disconnect() {
        fileHandle?.closeFile()
        fileHandle = nil
    }

    private func createUnixSocket() throws -> FileHandle {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw GPConnectError.helperNotRunning
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = Self.socketPath
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            path.withCString { cstr in
                _ = memcpy(ptr, cstr, path.utf8.count)
            }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, addrLen)
            }
        }

        guard result == 0 else {
            close(fd)
            throw GPConnectError.helperNotRunning
        }

        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
}

enum GPConnectError: LocalizedError {
    case helperNotRunning
    case authFailed(String)
    case connectionFailed(String)

    var errorDescription: String? {
        switch self {
        case .helperNotRunning:
            return "Helper daemon not running. Install with: sudo helper/install.sh"
        case .authFailed(let msg):
            return "Authentication failed: \(msg)"
        case .connectionFailed(let msg):
            return "Connection failed: \(msg)"
        }
    }
}
