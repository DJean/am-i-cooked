import Foundation

public enum HTTPError: Error, Equatable {
    case status(Int), rateLimited(TimeInterval)
}

// Never forward explicitly supplied authorization or cookies to another origin.
final class SameOriginRedirectDelegate: NSObject, URLSessionTaskDelegate {
    static func allowsRedirect(from original: URL?, to destination: URL?) -> Bool {
        guard let original, let destination,
              let scheme = original.scheme?.lowercased(), ["https", "http"].contains(scheme),
              destination.scheme?.lowercased() == scheme,
              let host = original.host?.lowercased(), destination.host?.lowercased() == host,
              destination.user == nil, destination.password == nil else { return false }
        let defaultPort = scheme == "https" ? 443 : 80
        return (original.port ?? defaultPort) == (destination.port ?? defaultPort)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(Self.allowsRedirect(from: task.originalRequest?.url, to: request.url) ? request : nil)
    }
}

public struct HTTPClient: Sendable {
    private let transport: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    public init() {
        self.init { request in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            let session = URLSession(configuration: configuration, delegate: SameOriginRedirectDelegate(), delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw HTTPError.status(0) }
            return (data, response)
        }
    }

    public init(transport: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)) {
        self.transport = transport
    }

    public func data(for request: URLRequest) async throws -> Data {
        var request = request
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.timeoutInterval = min(request.timeoutInterval, 15)
        let (data, response) = try await transport(request)
        if response.statusCode == 429 {
            throw HTTPError.rateLimited(Self.retryDelay(response.value(forHTTPHeaderField: "Retry-After")))
        }
        guard (200..<300).contains(response.statusCode) else { throw HTTPError.status(response.statusCode) }
        return data
    }

    static func retryDelay(_ value: String?, now: Date = Date()) -> TimeInterval {
        guard let value else { return 300 }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = Double(text) {
            return seconds.isFinite && seconds >= 0 ? min(seconds, 604_800) : 300
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.isLenient = false
        formatter.twoDigitStartDate = formatter.calendar.date(byAdding: .year, value: -50, to: now)
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) {
                return min(max(0, date.timeIntervalSince(now)), 604_800)
            }
        }
        return 300
    }
}

