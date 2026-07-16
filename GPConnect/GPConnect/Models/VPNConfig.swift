import Foundation

struct VPNConfig: Codable {
    var gateway: String
    var ipRanges: [IPRange]
    var openconnectPath: String?
    var userAgent: String
    var autoFillCredentials: Bool?
    var savedUsername: String?
    var highlightDisconnectedIcon: Bool?

    static let defaultConfig = VPNConfig(
        gateway: "",
        ipRanges: [],
        openconnectPath: nil,
        userAgent: "PAN GlobalProtect",
        autoFillCredentials: false,
        savedUsername: nil,
        highlightDisconnectedIcon: true
    )

    static var configURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("GPConnect")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }

    static func load() -> VPNConfig {
        guard let data = try? Data(contentsOf: configURL),
              let config = try? JSONDecoder().decode(VPNConfig.self, from: data) else {
            return defaultConfig
        }
        return config
    }

    func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: Self.configURL)
    }
}

struct IPRange: Codable, Identifiable, Hashable {
    var id: UUID
    var cidr: String
    var label: String
    var enabled: Bool

    init(id: UUID = UUID(), cidr: String, label: String = "", enabled: Bool = true) {
        self.id = id
        self.cidr = cidr
        self.label = label
        self.enabled = enabled
    }

    var displayName: String {
        label.isEmpty ? cidr : "\(label) (\(cidr))"
    }
}
