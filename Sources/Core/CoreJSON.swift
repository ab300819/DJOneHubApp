import Foundation

/// The decoding rules every answer from the core passes through.
///
/// This lives outside `StdioTransport` so the contract tests can decode captured
/// payloads through the very decoder the app uses. A test that built its own
/// decoder could pass while the app failed on a timestamp it spelled slightly
/// differently.
enum CoreJSON {
    /// Go emits RFC 3339 with fractional seconds, which `.iso8601` rejects, and
    /// omits them when they happen to be zero — so both spellings must parse.
    static let decoder: JSONDecoder = {
        // Format styles rather than ISO8601DateFormatter: they are Sendable, so
        // the decoding closure can hold them under strict concurrency.
        let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let plain = Date.ISO8601FormatStyle()

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = (try? withFraction.parse(text)) ?? (try? plain.parse(text)) {
                return date
            }
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "无法解析时间 \(text)"))
        }
        return decoder
    }()

    /// Whether an answer describes nothing at all. A method may legally reply
    /// `null` — `network.local` does exactly that when the module publishes no
    /// interface — and that is a state to render, not a decoding failure.
    static func isAbsent(_ payload: Data) -> Bool {
        payload.isEmpty || payload == Data("null".utf8)
    }
}
