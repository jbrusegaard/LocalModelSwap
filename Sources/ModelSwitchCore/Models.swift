import Foundation

public enum ServerKind: String, Sendable, Equatable, CaseIterable {
    case sushi
    case omlx
    case unknown

    public var label: String {
        switch self {
        case .sushi: return "sushi"
        case .omlx: return "oMLX"
        case .unknown: return "unknown"
        }
    }
}

public enum ModelState: String, Sendable, Equatable {
    case ready
    case loading
    case unloaded
    case error
    case unknown

    public var label: String {
        switch self {
        case .ready: return "ready"
        case .loading: return "loading"
        case .unloaded: return "unloaded"
        case .error: return "error"
        case .unknown: return "unknown"
        }
    }

    public var symbolName: String {
        switch self {
        case .ready: return "checkmark.circle.fill"
        case .loading: return "clock"
        case .unloaded: return "circle"
        case .error: return "exclamationmark.triangle.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    /// Sort order for the State column: busiest/attention states first.
    public var sortRank: Int {
        switch self {
        case .ready: return 0
        case .loading: return 1
        case .error: return 2
        case .unloaded: return 3
        case .unknown: return 4
        }
    }
}

public struct ServerModel: Identifiable, Sendable, Equatable {
    public let id: String
    public var loaded: Bool
    public let state: ModelState
    public let sizeBytes: Int64?
    public let contextLength: Int?
    /// True when this row only exists because the user added it by hand (it was
    /// not returned by the server's model scan).
    public let manual: Bool

    public init(
        id: String,
        loaded: Bool,
        state: ModelState,
        sizeBytes: Int64? = nil,
        contextLength: Int? = nil,
        manual: Bool = false
    ) {
        self.id = id
        self.loaded = loaded
        self.state = state
        self.sizeBytes = sizeBytes
        self.contextLength = contextLength
        self.manual = manual
    }

    public var shortName: String {
        id.split(separator: "/").last.map(String.init) ?? id
    }
}

public struct ServerHealth: Sendable, Equatable {
    public var up: Bool

    public init(up: Bool = false) {
        self.up = up
    }
}

public protocol ModelServerAPI: Sendable {
    var base: String { get }
    func fetchModels() async throws -> [ServerModel]
    func load(_ id: String) async throws
    func unload(_ id: String) async throws
    func health() async throws -> ServerHealth
}

public struct InferenceServer: Identifiable, Sendable {
    public let provider: ProviderConfiguration
    public let kind: ServerKind
    public let api: any ModelServerAPI

    public init(provider: ProviderConfiguration, kind: ServerKind, api: any ModelServerAPI) {
        self.provider = provider
        self.kind = kind
        self.api = api
    }

    public var id: String { provider.id }
    public var name: String { provider.name }
    public var base: String { provider.normalizedBaseURL }
    public var token: String { provider.apiKey }
    public var hostLabel: String { provider.hostLabel }
}

public struct ModelRef: Hashable, Sendable, Identifiable {
    public let serverID: String
    public let modelID: String

    public init(serverID: String, modelID: String) {
        self.serverID = serverID
        self.modelID = modelID
    }

    public var id: ModelRef { self }
}

public struct ModelRow: Identifiable, Sendable, Equatable {
    public let serverID: String
    public let serverName: String
    public let model: ServerModel
    /// Effective context written to settings.json for this model.
    public let contextTokens: String

    public init(serverID: String, serverName: String, model: ServerModel, contextTokens: String) {
        self.serverID = serverID
        self.serverName = serverName
        self.model = model
        self.contextTokens = contextTokens
    }

    public var id: ModelRef { ModelRef(serverID: serverID, modelID: model.id) }
    public var modelID: String { model.id }

    /// Sort key for the Size column; rows without a size group together.
    public var sizeForSort: Int64 { model.sizeBytes ?? Int64.min }
    /// Sort key for the Context column; non-numeric values group together.
    public var contextForSort: Int64 { Int64(contextTokens) ?? Int64.min }
    /// Sort key for the Source column; server-scanned models sort before manual ones.
    public var sourceForSort: Int { model.manual ? 1 : 0 }
}

public enum Format {
    public static func bytes(_ value: Int64?) -> String {
        guard let value, value > 0 else { return "—" }
        let gib = Double(value) / 1_073_741_824
        if gib >= 1 {
            return String(format: "%.1f GiB", gib)
        }
        let mib = Double(value) / 1_048_576
        return String(format: "%.0f MiB", mib)
    }

    public static func duration(_ seconds: Double) -> String {
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        let minutes = Int(seconds) / 60
        let remainder = Int(seconds) % 60
        return "\(minutes)m \(remainder)s"
    }

    public static func tokens(_ value: String) -> String {
        guard let number = Int64(value), number > 0 else { return value.isEmpty ? "—" : value }
        if number >= 1_000_000 { return String(format: "%.1fM", Double(number) / 1_000_000) }
        if number >= 1_000 { return String(format: "%.0fK", Double(number) / 1_000) }
        return "\(number)"
    }
}
