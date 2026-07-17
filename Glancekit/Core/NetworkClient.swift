import Foundation

/// Shared async HTTP helper used by all network-fetch glances (Stocks, GitHub,
/// Custom API). Thin wrapper over `URLSession` with JSON decoding and header
/// support. Keep plugin networking going through this so retry/timeout/logging
/// policy lives in one place.
struct NetworkClient {
    enum NetworkError: LocalizedError {
        case badURL(String)
        case http(Int, message: String? = nil)
        case decoding(String)

        var errorDescription: String? {
            switch self {
            case .badURL(let s): return "Invalid URL: \(s)"
            case .http(let code, let message):
                if let message, !message.isEmpty { return "HTTP \(code): \(message)" }
                return "HTTP \(code)"
            case .decoding(let s): return "Decode failed: \(s)"
            }
        }
    }

    var session: URLSession = .shared
    var timeout: TimeInterval = 15

    /// Fetch raw `Data` for a URL with optional headers.
    func data(from urlString: String, headers: [String: String] = [:]) async throws -> Data {
        try await send(to: urlString, method: "GET", body: nil, headers: headers)
    }

    /// Raw `Data` from a POST with a body (e.g. a GraphQL query).
    func postData(to urlString: String, body: Data, headers: [String: String] = [:]) async throws -> Data {
        try await send(to: urlString, method: "POST", body: body, headers: headers)
    }

    private func send(to urlString: String, method: String, body: Data?, headers: [String: String]) async throws -> Data {
        guard let url = URL(string: urlString) else { throw NetworkError.badURL(urlString) }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Glancekit/0.1 (macOS)", forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NetworkError.http(http.statusCode, message: Self.errorMessage(from: data, response: http))
        }
        return data
    }

    /// Best-effort human-readable reason for a failed response. GitHub (and most
    /// JSON APIs) return `{"message": "..."}`; if the primary rate limit is
    /// exhausted the response also carries `x-ratelimit-remaining: 0`, which we
    /// call out explicitly since it's a common cause of a 403.
    private static func errorMessage(from data: Data, response: HTTPURLResponse) -> String? {
        if response.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0" {
            return "API rate limit exceeded"
        }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = json["message"] as? String, !message.isEmpty {
            return message
        }
        return nil
    }

    /// Fetch and decode a `Decodable` type from a URL with optional headers.
    func get<T: Decodable>(_ type: T.Type,
                           from urlString: String,
                           headers: [String: String] = [:],
                           decoder: JSONDecoder = JSONDecoder()) async throws -> T {
        let data = try await self.data(from: urlString, headers: headers)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw NetworkError.decoding(error.localizedDescription)
        }
    }

    /// POST `body` and decode the response as `T`.
    func post<T: Decodable>(_ type: T.Type,
                            to urlString: String,
                            body: Data,
                            headers: [String: String] = [:],
                            decoder: JSONDecoder = JSONDecoder()) async throws -> T {
        let data = try await postData(to: urlString, body: body, headers: headers)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw NetworkError.decoding(error.localizedDescription)
        }
    }
}
