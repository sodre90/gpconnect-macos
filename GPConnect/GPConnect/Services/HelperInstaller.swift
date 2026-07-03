import Foundation

enum HelperInstaller {
    private static let socketPath = "/var/run/openconnect-helper.sock"

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: socketPath)
    }

    static func install() async throws {
        guard let scriptURL = Bundle.main.url(forResource: "install", withExtension: "sh", subdirectory: "helper") else {
            throw HelperInstallerError.scriptNotFound
        }

        try await Task.detached(priority: .userInitiated) {
            let escapedPath = scriptURL.path.replacingOccurrences(of: "\"", with: "\\\"")
            let appleScript = "do shell script \"\(escapedPath)\" with administrator privileges"

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", appleScript]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? "unknown error"
                throw HelperInstallerError.installFailed(output)
            }
        }.value
    }
}

enum HelperInstallerError: LocalizedError {
    case scriptNotFound
    case installFailed(String)

    var errorDescription: String? {
        switch self {
        case .scriptNotFound:
            return "Could not find the helper install script inside the app bundle."
        case .installFailed(let output):
            return "Helper install failed: \(output)"
        }
    }
}
