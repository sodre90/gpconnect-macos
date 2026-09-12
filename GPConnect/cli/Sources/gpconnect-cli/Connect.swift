import Foundation
import Darwin

private let helperSocketPath = "/var/run/openconnect-helper.sock"

private var daemonFD: Int32 = -1
private var gotSIGINT = false

private func handleSIGINT(_ signal: Int32) {
    gotSIGINT = true
    if daemonFD >= 0 {
        // shutdown() is async-signal-safe and unblocks the pending read(); the daemon
        // treats EOF on its side as the order to terminate openconnect.
        shutdown(daemonFD, SHUT_RDWR)
    }
}

private func openHelperSocket() throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw CLIError.message("could not create a Unix socket") }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    _ = withUnsafeMutableBytes(of: &addr.sun_path) { pathBytes in
        helperSocketPath.withCString { memcpy(pathBytes.baseAddress!, $0, strlen($0) + 1) }
    }

    let result = withUnsafePointer(to: &addr) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard result == 0 else {
        close(fd)
        throw CLIError.message("helper daemon not running (\(helperSocketPath)). Install with: sudo helper/install.sh")
    }
    return fd
}

func readHiddenLine(prompt: String) throws -> String {
    let fd = FileHandle.standardInput.fileDescriptor
    var original = termios()
    let hasTerminals = tcgetattr(fd, &original) == 0
    if hasTerminals {
        var masked = original
        masked.c_lflag &= ~UInt(ECHO)
        tcsetattr(fd, TCSADRAIN, &masked)
    }
    defer {
        if hasTerminals { tcsetattr(fd, TCSADRAIN, &original) }
        fputs("\n", stderr)
    }
    fputs(prompt, stderr)
    guard let line = readLine(strippingNewline: true), !line.isEmpty else {
        throw CLIError.message("no input on terminal")
    }
    return line
}

private func appSocketPath() -> String {
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    return appSupport.appendingPathComponent("GPConnect/cli.sock").path
}

/// Ask the running GPConnect menu bar app to perform the interactive SAML login
/// (proximity + push happen in its webview; nothing to see for a remote CLI user)
/// and hand the auth result back over the app's 0600 local socket.
func loginViaApp() throws -> SAMLResultCLI {
    let path = appSocketPath()
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw CLIError.message("could not create a Unix socket") }
    defer { close(fd) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    _ = withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        path.withCString { memcpy(raw.baseAddress!, $0, strlen($0) + 1) }
    }
    let connected = withUnsafePointer(to: &addr) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard connected == 0 else {
        throw CLIError.message("GPConnect app is not listening (\(path)) — launch it, or use --http")
    }

    let request = Data("{\"command\":\"login\"}\n".utf8)
    request.withUnsafeBytes { raw in _ = write(fd, raw.baseAddress, raw.count) }

    var chunk = [UInt8](repeating: 0, count: 4096)
    var incoming = Data()
    while !incoming.contains(0x0A) {
        let n = read(fd, &chunk, chunk.count)
        if n <= 0 { throw CLIError.message("GPConnect closed the connection") }
        incoming.append(contentsOf: chunk[0..<n])
    }
    guard let json = try? JSONSerialization.jsonObject(with: incoming) as? [String: Any] else {
        throw CLIError.message("GPConnect sent an unreadable reply")
    }
    guard json["ok"] as? Bool == true,
          let username = json["username"] as? String,
          let cookie = json["cookie"] as? String,
          let cookieName = json["cookieName"] as? String
    else {
        throw CLIError.message("GPConnect: \(json["error"] as? String ?? "login failed")")
    }
    return SAMLResultCLI(username: username, cookie: cookie, cookieName: cookieName, server: json["server"] as? String ?? "")
}

@MainActor
func connectCommand(args: [String]) async {
    do {
        try await runConnect(args: args)
    } catch let error as CLIError {
        fputs("Error: \(error.errorDescription ?? "unknown")\n", stderr)
        exit(1)
    } catch {
        fputs("Error: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

@MainActor
func runConnect(args: [String]) async throws {
    cliVerbose = args.contains("--verbose") || args.contains("-v")
    let dryRun = args.contains("--dry-run")
    let mfa = getArg(args, flag: "--mfa") ?? "push"
    guard mfa == "push" || mfa == "totp" else {
        throw CLIError.message("--mfa must be push or totp")
    }
    guard let config = loadConfig() else {
        throw CLIError.message("config not found at \(configURL().path) — run the GPConnect app once to create it")
    }
    guard !config.gateway.isEmpty else {
        throw CLIError.message("no gateway configured — gpconnect config set --gateway <addr>")
    }
    let enabledRanges = config.ipRanges.filter(\.enabled).map(\.cidr)
    let sliceArg = enabledRanges.joined(separator: " ")

    let mode = args.contains("--app") ? "app" : (args.contains("--http") ? "http" : "webview")
    let modeLabel = ["app": "GPConnect app handoff (--app)",
                     "http": "headless HTTP (--http)",
                     "webview": "hidden background browser (default)"][mode]!
    print("Gateway:  \(config.gateway)")
    print("Split:    \(enabledRanges.isEmpty ? "no — full tunnel (0 enabled ranges)" : "\(enabledRanges.count) range(s) via vpn-slice")")
    print("Login:    \(modeLabel)")

    if dryRun {
        let target = try await fetchSPLoginRequest(gateway: config.gateway, userAgent: config.userAgent, session: makeTrustingSession())
        print("IdP:      \(target.url.host ?? "?") (\(target.url.path), \(target.fields.count) form field(s))")
        var planned = ["openconnect", "--protocol=gp", "--user=<after login>", "--os=mac-intel",
                       "--usergroup=gateway:<cookie-name>", "--useragent=\(config.userAgent)",
                       "--passwd-on-stdin", config.gateway]
        if !sliceArg.isEmpty { planned += ["-s", "vpn-slice \(sliceArg)"] }
        print("Dry run — would exec:")
        print("  \(planned.joined(separator: " "))")
        return
    }

    let result: SAMLResultCLI
    if mode == "app" {
        print("Requesting login from the running GPConnect app — approve the Okta Verify push on your phone.")
        result = try loginViaApp()
    } else {
        var user = getArg(args, flag: "--user") ?? config.savedUsername ?? ""
        if user.isEmpty { user = try readHiddenLine(prompt: "Okta username: ") }
        var password = ProcessInfo.processInfo.environment["GPCONNECT_PASSWORD"] ?? ""
        if password.isEmpty { password = try readHiddenLine(prompt: "Okta password for \(user): ") }
        switch mode {
        case "http":
            result = try await loginHeadless(
                gateway: config.gateway,
                gpUserAgent: config.userAgent,
                user: user,
                password: password,
                mfa: mfa
            )
        default:
            print("Opening a hidden browser window in this Mac's console session — approve the Okta Verify push on your phone.")
            result = try loginViaWebView(
                gateway: config.gateway,
                userAgent: config.userAgent,
                username: user,
                password: password
            )
        }
    }
    print("Authenticated as \(result.username) (\(result.cookieName))")

    var openconnectArgs = [
        "--protocol=gp",
        "--user=\(result.username)",
        "--os=mac-intel",
        "--usergroup=gateway:\(result.cookieName)",
        "--useragent=\(config.userAgent)",
        "--passwd-on-stdin",
        config.gateway,
    ]
    if !sliceArg.isEmpty {
        openconnectArgs.append(contentsOf: ["-s", "vpn-slice \(sliceArg)"])
    }

    let fd = try openHelperSocket()
    daemonFD = fd
    signal(SIGINT, handleSIGINT)

    var payload = try JSONSerialization.data(withJSONObject: ["args": openconnectArgs, "cookie": result.cookie])
    payload.append(0x0A)
    payload.withUnsafeBytes { buffer in
        var written = 0
        while written < buffer.count {
            let n = Darwin.write(fd, buffer.baseAddress!.advanced(by: written), buffer.count - written)
            if n <= 0 { break }
            written += n
        }
    }
    print("Tunnel starting — streaming openconnect output, Ctrl+C to disconnect.")

    let out = FileHandle.standardOutput
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = read(fd, &buffer, buffer.count)
        if n > 0 {
            out.write(Data(bytes: buffer, count: n))
            continue
        }
        if n < 0 && errno == EINTR { continue }
        break
    }
    close(fd)
    print(gotSIGINT ? "Disconnected." : "openconnect exited.")
    exit(gotSIGINT ? 0 : 2)
}
