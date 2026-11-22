import Foundation

public struct HTTPResponse: Sendable, Equatable {
    public let status: Int
    public let body: Data

    public var object: JSONValue? {
        try? JSONValue.parse(body)
    }
}

/// HTTP client for one provider base. Auth is only `Authorization: Bearer`
/// (modelswitch never sends `x-api-key`), responses are capped at 1 MiB, and
/// load calls use a per-request 30-minute timeout.
public final class HTTPClient: @unchecked Sendable {
    public let base: String
    public let token: String
    private let session: URLSession

    public init(base: String, token: String, session: URLSession? = nil) {
        var trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        self.base = trimmed
        self.token = token
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 1800
            configuration.timeoutIntervalForResource = 3600
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration)
        }
    }

    public func get(_ path: String, timeout: TimeInterval = 15) async throws -> HTTPResponse {
        try await perform(method: "GET", path: path, body: nil, timeout: timeout)
    }

    public func post(_ path: String, json: JSONValue?, timeout: TimeInterval = 1800) async throws -> HTTPResponse {
        try await perform(method: "POST", path: path, body: json, timeout: timeout)
    }

    private func perform(
        method: String,
        path: String,
        body: JSONValue?,
        timeout: TimeInterval
    ) async throws -> HTTPResponse {
        guard let url = URL(string: base + path) else {
            throw APIError.server("Invalid URL: \(base + path)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        if let body {
            request.httpBody = try body.serializedData(pretty: false)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw APIError.transport("Non-HTTP response from \(url.absoluteString)")
            }
            let capped = data.count > 1_048_576 ? Data(data.prefix(1_048_576)) : data
            return HTTPResponse(status: http.statusCode, body: capped)
        } catch let error as APIError {
            throw error
        } catch let error as URLError {
            if error.code == .cancelled || Task.isCancelled {
                throw CancellationError()
            }
            throw APIError.transport(error.localizedDescription)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw APIError.transport(error.localizedDescription)
        }
    }
}
