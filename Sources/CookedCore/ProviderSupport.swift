import Foundation

// Only credential metadata is decoded. Credentials never enter snapshots or diagnostics.
public typealias CredentialCommand = @Sendable (String, [String]) -> String?

func providerDate(_ text: String?) -> Date? {
    guard let text else { return nil }
    let iso = ISO8601DateFormatter()
    if let date = iso.date(from: text) { return date }
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return iso.date(from: text)
}

struct UsageCache<Value: Sendable>: Sendable {
    var value: Value?
    var retryAt: Date?
    func waiting(now: Date) -> String? {
        guard let retryAt, retryAt > now else { return nil }
        return "Rate limited; retry in \(Int(ceil(retryAt.timeIntervalSince(now) / 60)))m" + (value == nil ? "." : ". Showing previous usage.")
    }
    mutating func failure(_ error: any Error, now: Date, login: String) -> String {
        switch error {
        case HTTPError.rateLimited(let seconds):
            retryAt = now.addingTimeInterval(seconds)
            return waiting(now: now) ?? "Rate limited; retrying."
        case HTTPError.status(401): return login
        case HTTPError.status(let code): return "Usage API returned HTTP \(code)." + stale
        case is DecodingError: return "Usage API response format changed." + stale
        default: return "Usage API unavailable; retrying." + stale
        }
    }
    var stale: String { value == nil ? "" : " Showing previous usage." }
}

