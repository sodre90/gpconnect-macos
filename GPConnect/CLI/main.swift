import Foundation

let version = "1.0.0"

struct CLIConfig: Codable {
    var gateway: String
    var ipRanges: [CLIIPRange]
    var openconnectPath: String?
    var userAgent: String
    var autoFillCredentials: Bool?
    var savedUsername: String?
}

struct CLIIPRange: Codable {
    var cidr: String
    var label: String
    var enabled: Bool
}

func configURL() -> URL {
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    return appSupport.appendingPathComponent("GPConnect/config.json")
}

func loadConfig() -> CLIConfig? {
    guard let data = try? Data(contentsOf: configURL()),
          let config = try? JSONDecoder().decode(CLIConfig.self, from: data) else {
        return nil
    }
    return config
}

func printUsage() {
    let usage = """
    gpconnect - CLI companion for GPConnect menu bar app

    USAGE:
        gpconnect <command> [options]

    COMMANDS:
        status          Show VPN connection status
        ranges          List configured IP ranges
        ranges add      Add an IP range (--cidr <cidr> [--label <label>])
        ranges remove   Remove an IP range (--cidr <cidr>)
        ranges enable   Enable a range (--cidr <cidr>)
        ranges disable  Disable a range (--cidr <cidr>)
        config          Show current configuration
        config set      Set a config value (--gateway <addr> | --user-agent <ua>)
        vpn-slice-args  Output the vpn-slice argument string
        version         Show version

    CONFIG FILE:
        \(configURL().path)
    """
    print(usage)
}

func showStatus() {
    let socketPath = "/var/run/openconnect-helper.sock"
    let helperRunning = FileManager.default.fileExists(atPath: socketPath)
    print("Helper daemon: \(helperRunning ? "running" : "not running")")

    if let config = loadConfig() {
        print("Gateway: \(config.gateway)")
        let enabled = config.ipRanges.filter(\.enabled).count
        print("IP ranges: \(enabled)/\(config.ipRanges.count) enabled")
    } else {
        print("Config: not found (run the GPConnect app once to create it)")
    }
}

func showRanges() {
    guard let config = loadConfig() else {
        fputs("Error: config not found at \(configURL().path)\n", stderr)
        exit(1)
    }
    let maxCIDR = config.ipRanges.map(\.cidr.count).max() ?? 18
    for range in config.ipRanges {
        let status = range.enabled ? "+" : "-"
        let cidr = range.cidr.padding(toLength: maxCIDR, withPad: " ", startingAt: 0)
        let label = range.label.isEmpty ? "" : " # \(range.label)"
        print("[\(status)] \(cidr)\(label)")
    }
}

func addRange(cidr: String, label: String) {
    guard var config = loadConfig() else {
        fputs("Error: config not found\n", stderr)
        exit(1)
    }
    if config.ipRanges.contains(where: { $0.cidr == cidr }) {
        fputs("Range \(cidr) already exists\n", stderr)
        exit(1)
    }
    config.ipRanges.append(CLIIPRange(cidr: cidr, label: label, enabled: true))
    saveConfig(config)
    print("Added \(cidr)")
}

func removeRange(cidr: String) {
    guard var config = loadConfig() else {
        fputs("Error: config not found\n", stderr)
        exit(1)
    }
    let before = config.ipRanges.count
    config.ipRanges.removeAll { $0.cidr == cidr }
    if config.ipRanges.count == before {
        fputs("Range \(cidr) not found\n", stderr)
        exit(1)
    }
    saveConfig(config)
    print("Removed \(cidr)")
}

func setRangeEnabled(cidr: String, enabled: Bool) {
    guard var config = loadConfig() else {
        fputs("Error: config not found\n", stderr)
        exit(1)
    }
    guard let idx = config.ipRanges.firstIndex(where: { $0.cidr == cidr }) else {
        fputs("Range \(cidr) not found\n", stderr)
        exit(1)
    }
    config.ipRanges[idx].enabled = enabled
    saveConfig(config)
    print("\(enabled ? "Enabled" : "Disabled") \(cidr)")
}

func showConfig() {
    guard let config = loadConfig() else {
        fputs("Error: config not found at \(configURL().path)\n", stderr)
        exit(1)
    }
    print("Gateway:    \(config.gateway)")
    print("User-Agent: \(config.userAgent)")
    print("Config at:  \(configURL().path)")
}

func setConfig(key: String, value: String) {
    guard var config = loadConfig() else {
        fputs("Error: config not found\n", stderr)
        exit(1)
    }
    switch key {
    case "gateway":
        config.gateway = value
    case "user-agent":
        config.userAgent = value
    default:
        fputs("Unknown config key: \(key)\n", stderr)
        exit(1)
    }
    saveConfig(config)
    print("Set \(key) = \(value)")
}

func vpnSliceArgs() {
    guard let config = loadConfig() else {
        fputs("Error: config not found\n", stderr)
        exit(1)
    }
    let args = config.ipRanges.filter(\.enabled).map(\.cidr).joined(separator: " ")
    print(args)
}

func saveConfig(_ config: CLIConfig) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(config) else {
        fputs("Error: failed to encode config\n", stderr)
        exit(1)
    }
    do {
        try data.write(to: configURL())
    } catch {
        fputs("Error: failed to write config: \(error)\n", stderr)
        exit(1)
    }
}

func getArg(_ args: [String], flag: String) -> String? {
    guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else { return nil }
    return args[idx + 1]
}

// MARK: - Main

let args = Array(CommandLine.arguments.dropFirst())

guard let command = args.first else {
    printUsage()
    exit(0)
}

switch command {
case "status":
    showStatus()
case "ranges":
    if args.count > 1 {
        switch args[1] {
        case "add":
            guard let cidr = getArg(args, flag: "--cidr") else {
                fputs("Usage: gpconnect ranges add --cidr <cidr> [--label <label>]\n", stderr)
                exit(1)
            }
            addRange(cidr: cidr, label: getArg(args, flag: "--label") ?? "")
        case "remove":
            guard let cidr = getArg(args, flag: "--cidr") else {
                fputs("Usage: gpconnect ranges remove --cidr <cidr>\n", stderr)
                exit(1)
            }
            removeRange(cidr: cidr)
        case "enable":
            guard let cidr = getArg(args, flag: "--cidr") else {
                fputs("Usage: gpconnect ranges enable --cidr <cidr>\n", stderr)
                exit(1)
            }
            setRangeEnabled(cidr: cidr, enabled: true)
        case "disable":
            guard let cidr = getArg(args, flag: "--cidr") else {
                fputs("Usage: gpconnect ranges disable --cidr <cidr>\n", stderr)
                exit(1)
            }
            setRangeEnabled(cidr: cidr, enabled: false)
        default:
            showRanges()
        }
    } else {
        showRanges()
    }
case "config":
    if args.count > 1 && args[1] == "set" {
        if let gateway = getArg(args, flag: "--gateway") {
            setConfig(key: "gateway", value: gateway)
        } else if let ua = getArg(args, flag: "--user-agent") {
            setConfig(key: "user-agent", value: ua)
        } else {
            fputs("Usage: gpconnect config set --gateway <addr> | --user-agent <ua>\n", stderr)
            exit(1)
        }
    } else {
        showConfig()
    }
case "vpn-slice-args":
    vpnSliceArgs()
case "version":
    print("gpconnect \(version)")
case "--help", "-h", "help":
    printUsage()
default:
    fputs("Unknown command: \(command)\n", stderr)
    printUsage()
    exit(1)
}
