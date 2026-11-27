import Foundation

struct VPNConfig: Codable {
    var gateway: String
    var ipRanges: [IPRange]
    var vpnDnsDomains: [String]?
    var openconnectPath: String?
    var userAgent: String
    var autoFillCredentials: Bool?
    var savedUsername: String?
    var highlightDisconnectedIcon: Bool?
    var notifyOnDisconnect: Bool?
    var autoDisconnectEnabled: Bool?
    var autoDisconnectMinutes: Int?
    var connectedReminderEnabled: Bool?
    var connectedReminderMinutes: Int?

    static let defaultConfig = VPNConfig(
        gateway: "",
        ipRanges: [],
        vpnDnsDomains: nil,
        openconnectPath: nil,
        userAgent: "PAN GlobalProtect",
        autoFillCredentials: false,
        savedUsername: nil,
        highlightDisconnectedIcon: true,
        notifyOnDisconnect: true,
        autoDisconnectEnabled: false,
        autoDisconnectMinutes: 240,
        connectedReminderEnabled: false,
        connectedReminderMinutes: 240
    )

    static var configURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("GPConnect")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }

    static func load() throws -> VPNConfig {
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            return defaultConfig
        }
        let data = try Data(contentsOf: configURL)
        return try JSONDecoder().decode(VPNConfig.self, from: data)
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

    /// The CLI (and hand edits) may write ranges without an `id`; it is only a SwiftUI
    /// identity, so a missing one gets a fresh UUID instead of failing the whole config.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        cidr = try container.decode(String.self, forKey: .cidr)
        label = try container.decode(String.self, forKey: .label)
        enabled = try container.decode(Bool.self, forKey: .enabled)
    }

    var displayName: String {
        label.isEmpty ? cidr : "\(label) (\(cidr))"
    }
}

extension DecodingError {
    var readableDescription: String {
        switch self {
        case .keyNotFound(_, let context),
             .typeMismatch(_, let context),
             .valueNotFound(_, let context),
             .dataCorrupted(let context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? context.debugDescription : "\(path): \(context.debugDescription)"
        @unknown default:
            return localizedDescription
        }
    }
}
