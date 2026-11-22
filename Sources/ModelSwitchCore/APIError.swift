import Foundation

/// Errors surfaced by the server adapters and the switch engine.
public enum APIError: Error, Equatable, LocalizedError, Sendable {
    case transport(String)
    case http(status: Int, message: String)
    case unauthorized(status: Int, message: String)
    case server(String)
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .transport(let message): return message
        case .http(_, let message): return message
        case .unauthorized(_, let message): return message
        case .server(let message): return message
        case .decoding(let message): return message
        }
    }

    public var message: String {
        errorDescription ?? "Unknown error"
    }

    public var isAuth: Bool {
        if case .unauthorized = self { return true }
        return false
    }

    /// Builds the error the Go tool would report for a non-2xx response:
    /// FastAPI `{detail}`, OpenAI `{error:{message}}`, then a simple
    /// `{message|error|reason}`, truncated to 240 characters.
    public static func from(status: Int, data: Data) -> APIError {
        var message = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if let object = try? JSONValue.parse(data) {
            if let detail = object["detail"], !detail.isNull {
                message = scalarDescription(detail)
            } else if let sub = object["error"]?["message"]?.stringValue {
                message = sub
            } else if let sub = object["message"]?.stringValue {
                message = sub
            } else if let sub = object["error"]?.stringValue {
                message = sub
            } else if let sub = object["reason"]?.stringValue {
                message = sub
            }
        }

        if message.isEmpty {
            message = "HTTP \(status)"
        }
        if message.count > 240 {
            message = String(message.prefix(240)) + "…"
        }

        if status == 401 || status == 403 {
            return .unauthorized(status: status, message: message)
        }
        return .http(status: status, message: message)
    }

    private static func scalarDescription(_ value: JSONValue) -> String {
        if let string = value.stringValue { return string }
        if let number = value.scalarString { return number }
        if case .array(let values) = value {
            return values.prefix(3).map(scalarDescription).joined(separator: ", ")
        }
        if case .object(let pairs) = value,
           let message = pairs.first(where: { $0.key == "message" })?.value.stringValue {
            return message
        }
        return value.compactText
    }
}
