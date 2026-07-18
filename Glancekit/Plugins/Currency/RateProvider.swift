import Foundation

/// A snapshot of FX rates for one base currency at one point in time.
///
/// `open.er-api.com` returns only the latest rates (no history), so the plugin
/// keeps its own rolling series and derives change% and sparklines from these
/// snapshots over time.
struct RateSnapshot: Equatable {
    /// The base currency the rates are quoted against, e.g. "USD".
    let base: String
    /// Target-code → rate (units of target per 1 unit of base), e.g. "EUR": 0.92.
    let rates: [String: Double]
    /// When the source last published these rates (best effort).
    let updated: Date
}

/// The pluggable seam for FX data. `OpenERateProvider` is the keyless default.
/// New providers (a keyed premium source, a cross-rate calculator, …) drop in
/// behind this protocol, mirroring the Stocks plugin's `QuoteProvider`.
protocol RateProvider {
    func fetchRates(base: String) async throws -> RateSnapshot
}

// MARK: - open.er-api.com (keyless default)

/// Uses the open, keyless `open.er-api.com` endpoint:
/// `GET https://open.er-api.com/v6/latest/{BASE}`.
///
/// Returns `{"result":"success","base_code":"USD","time_last_update_unix":...,
/// "rates":{"EUR":0.92,...}}`. A `result` other than `"success"` is surfaced as
/// an error rather than silently yielding empty data.
struct OpenERateProvider: RateProvider {
    var client = NetworkClient()

    func fetchRates(base: String) async throws -> RateSnapshot {
        let code = base.uppercased()
        let encoded = code.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? code
        let url = "https://open.er-api.com/v6/latest/\(encoded)"
        let response = try await client.get(OpenERateResponse.self, from: url)

        guard response.result == "success" else {
            let reason = response.errorType ?? response.result ?? "unknown error"
            throw NetworkClient.NetworkError.http(200, message: "Rate lookup failed: \(reason)")
        }
        let updated = response.timeLastUpdateUnix.map { Date(timeIntervalSince1970: $0) } ?? Date()
        return RateSnapshot(
            base: response.baseCode ?? code,
            rates: response.rates ?? [:],
            updated: updated
        )
    }
}

// Minimal Codable shape for the open.er-api v6 payload.
private struct OpenERateResponse: Decodable {
    let result: String?
    let baseCode: String?
    let timeLastUpdateUnix: Double?
    let rates: [String: Double]?
    /// Present only on `result == "error"`, e.g. "unsupported-code".
    let errorType: String?

    enum CodingKeys: String, CodingKey {
        case result
        case baseCode = "base_code"
        case timeLastUpdateUnix = "time_last_update_unix"
        case rates
        case errorType = "error-type"
    }
}
