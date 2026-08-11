import Foundation

/// How the UI reaches the DJOneHub core.
///
/// Today the only implementation talks HTTP to a locally spawned core process.
/// Keeping the UI behind this protocol is what allows an iPad build to swap in
/// a DriverKit-backed transport later without touching any view code.
protocol ModemTransport: Sendable {
    func health() async throws -> Health
    func status() async throws -> ModemStatus
    func executeAT(_ command: String) async throws -> String
}

extension ModemTransport {
    /// Polls `/api/health` until the core answers or the deadline passes.
    /// Readiness is a property of the connection, not of how the core was
    /// launched, so it lives here rather than on the process wrapper.
    func waitUntilReady(timeout: TimeInterval = 15) async throws -> Health {
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: Error?
        while Date() < deadline {
            do {
                return try await health()
            } catch {
                lastError = error
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        throw TransportError.coreUnavailable(lastError?.localizedDescription ?? "启动超时")
    }
}

enum TransportError: LocalizedError {
    case badStatus(Int, String)
    case coreUnavailable(String)

    var errorDescription: String? {
        switch self {
        case let .badStatus(code, body):
            "核心返回 HTTP \(code)：\(body)"
        case let .coreUnavailable(detail):
            "无法连接 DJOneHub 核心：\(detail)"
        }
    }
}

/// Talks to the Go core over its existing JSON API.
struct HTTPTransport: ModemTransport {
    let baseURL: URL
    private let session: URLSession

    init(baseURL: URL, timeout: TimeInterval = 30) {
        self.baseURL = baseURL
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        session = URLSession(configuration: config)
    }

    func health() async throws -> Health {
        try await get("/api/health")
    }

    func status() async throws -> ModemStatus {
        try await get("/api/status")
    }

    func executeAT(_ command: String) async throws -> String {
        struct Body: Encodable { let command: String }
        struct Reply: Decodable { let response: String }
        let reply: Reply = try await post("/api/at", body: Body(command: command))
        return reply.response
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "GET"
        return try await send(request)
    }

    private func post<Body: Encodable, T: Decodable>(_ path: String, body: Body) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await send(request)
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw TransportError.coreUnavailable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw TransportError.coreUnavailable("响应不是 HTTP")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw TransportError.badStatus(http.statusCode, String(decoding: data, as: UTF8.self))
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
