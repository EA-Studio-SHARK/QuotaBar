import Foundation

enum HTTP {
    static func get(
        url: URL,
        headers: [String: String],
        timeout: TimeInterval = 20
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw QuotaError.other("无效响应")
        }
        return (data, http)
    }

    static func post(
        url: URL,
        headers: [String: String],
        body: Data,
        timeout: TimeInterval = 20
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = body
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw QuotaError.other("无效响应")
        }
        return (data, http)
    }

    static func requireOK(_ data: Data, _ http: HTTPURLResponse) throws -> Data {
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw QuotaError.http(http.statusCode, String(body.prefix(200)))
        }
        return data
    }
}

enum ISO8601 {
    static let withFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parse(_ s: String?) -> Date? {
        guard let s else { return nil }
        return withFractional.date(from: s) ?? plain.date(from: s)
    }
}

enum Formatters {
    static func countdown(to date: Date?) -> String {
        guard let date else { return "" }
        let secs = Int(date.timeIntervalSinceNow)
        if secs <= 0 { return "已重置" }
        let h = secs / 3600
        let m = (secs % 3600) / 60
        if h >= 48 {
            let d = h / 24
            return "还剩 \(d) 天"
        }
        if h > 0 { return "还剩 \(h)h \(m)m" }
        return "还剩 \(m) 分钟"
    }

    static func moneyCents(_ cents: Int) -> String {
        String(format: "$%.2f", Double(cents) / 100.0)
    }

    static func relativeDate(_ date: Date?) -> String {
        guard let date else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
}
