import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import MCP

/// Oracle-only OpenAI-compatible `/chat/completions` provider. It has no tools and no workspace
/// access, so it cannot back `agent_run`. The API key is sent only in the `Authorization` header;
/// it is never forwarded to child processes or included in error text.
package struct DirectHeadlessOpenAICompatibleClient {
    struct Configuration: Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        let endpoint: URL
        let apiKey: String?

        /// Diagnostics, assertion failures, and `dump` show only whether a key is set.
        var description: String {
            "Configuration(endpoint: \(endpoint.absoluteString), apiKey: \(apiKey == nil ? "<unset>" : "<set>"))"
        }

        var debugDescription: String {
            description
        }

        var customMirror: Mirror {
            Mirror(self, children: ["endpoint": endpoint, "apiKey": apiKey == nil ? "<unset>" : "<set>"])
        }
    }

    struct Message: Equatable {
        let role: String
        let content: String
    }

    static let baseURLKey = "REPOPROMPT_MCP_HEADLESS_OPENAI_BASE_URL"
    static let apiKeyKey = "REPOPROMPT_MCP_HEADLESS_OPENAI_API_KEY"
    static let errorDetailLimit = 500

    private let sessionConfiguration: URLSessionConfiguration

    package init(sessionConfiguration: URLSessionConfiguration = .ephemeral) {
        self.sessionConfiguration = sessionConfiguration
    }

    /// Reads `REPOPROMPT_MCP_HEADLESS_OPENAI_BASE_URL` (an `http`/`https` API root such as
    /// `https://api.openai.com/v1`; a trailing `/chat/completions` is accepted) and the optional
    /// `REPOPROMPT_MCP_HEADLESS_OPENAI_API_KEY`.
    static func configuration(
        from environment: [String: String]
    ) -> (configuration: Configuration?, unavailableReason: String?) {
        let raw = environment[baseURLKey]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else {
            return (nil, "OpenAI-compatible provider is not configured; set \(baseURLKey) in the repoprompt-mcp process environment.")
        }
        guard var components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              components.host?.isEmpty == false
        else {
            return (nil, "\(baseURLKey) is not a valid http(s) URL.")
        }
        guard components.query == nil, components.fragment == nil else {
            return (nil, "\(baseURLKey) must not contain a query or fragment.")
        }
        var path = components.path
        while path.hasSuffix("/") {
            path.removeLast()
        }
        if path.hasSuffix("/chat/completions") {
            path.removeLast("/chat/completions".count)
        }
        components.path = path + "/chat/completions"
        guard let url = components.url else {
            return (nil, "\(baseURLKey) is not a valid http(s) URL.")
        }
        let key = environment[apiKeyKey]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (Configuration(endpoint: url, apiKey: key?.isEmpty == false ? key : nil), nil)
    }

    static func makeRequest(configuration: Configuration, model: String, messages: [Message]) throws -> URLRequest {
        var request = URLRequest(url: configuration.endpoint, timeoutInterval: 600)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey = configuration.apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": messages.map { ["role": $0.role, "content": $0.content] }
        ])
        return request
    }

    static func parseResponse(
        data: Data,
        statusCode: Int,
        configuration: Configuration
    ) throws -> DirectHeadlessProviderCoordinator.TurnOutput {
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard (200 ..< 300).contains(statusCode) else {
            let detail = ((object?["error"] as? [String: Any])?["message"] as? String)
                ?? (object?["error"] as? String)
                ?? String(decoding: data, as: UTF8.self)
            throw error("HTTP \(statusCode): \(detail)", configuration: configuration)
        }
        guard let choices = object?["choices"] as? [[String: Any]],
              let content = (choices.first?["message"] as? [String: Any])?["content"] as? String
        else {
            throw error("returned no assistant content", configuration: configuration)
        }
        return .init(assistantText: content, providerSessionID: nil)
    }

    func complete(
        configuration: Configuration,
        model: String,
        messages: [Message]
    ) async throws -> DirectHeadlessProviderCoordinator.TurnOutput {
        let request = try Self.makeRequest(configuration: configuration, model: model, messages: messages)
        let transfer = Transfer()
        // A delegate-driven task, because corelibs follows redirects for completion-handler tasks
        // without consulting the delegate and copies `Authorization` to the new host.
        let session = URLSession(configuration: sessionConfiguration, delegate: transfer, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, statusCode): (Data, Int) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                transfer.start(session.dataTask(with: request)) { result in
                    continuation.resume(with: result.mapError { error -> Error in
                        (error as? URLError)?.code == .cancelled
                            ? CancellationError()
                            : Self.error("request failed: \(error.localizedDescription)", configuration: configuration)
                    })
                }
            }
        } onCancel: {
            transfer.cancel()
        }
        return try Self.parseResponse(data: data, statusCode: statusCode, configuration: configuration)
    }

    /// Servers sometimes echo the credential they rejected, so it is redacted from the whole
    /// message before the message is shortened; truncating first could keep a key's prefix.
    private static func error(_ detail: String, configuration: Configuration) -> MCPError {
        var text = detail
        if let apiKey = configuration.apiKey {
            text = text.replacingOccurrences(of: apiKey, with: "[redacted]")
        }
        if text.count > errorDetailLimit {
            text = String(text.prefix(errorDetailLimit)) + "…"
        }
        return MCPError.internalError("openaiCompatible \(text)")
    }
}

/// One request's delegate: collects the body, refuses redirects that leave the original
/// scheme/host/port, and lets cancellation that races `start` still cancel the task.
private final class Transfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var isCancelled = false
    private var body = Data()
    private var completion: ((Result<(Data, Int), Error>) -> Void)?

    func start(_ task: URLSessionDataTask, completion: @escaping (Result<(Data, Int), Error>) -> Void) {
        lock.lock()
        self.task = task
        self.completion = completion
        let cancelled = isCancelled
        lock.unlock()
        task.resume()
        if cancelled { task.cancel() }
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let task = task
        lock.unlock()
        task?.cancel()
    }

    func urlSession(
        _: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(Self.sameOrigin(task.originalRequest?.url, request.url) ? request : nil)
    }

    func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        body.append(data)
        lock.unlock()
    }

    func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let (completion, data) = (self.completion, body)
        self.completion = nil
        lock.unlock()
        if let error {
            completion?(.failure(error))
        } else if let response = task.response as? HTTPURLResponse {
            completion?(.success((data, response.statusCode)))
        } else {
            completion?(.failure(URLError(.badServerResponse)))
        }
    }

    private static func sameOrigin(_ lhs: URL?, _ rhs: URL?) -> Bool {
        guard let lhs, let rhs else { return false }
        return lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && lhs.port == rhs.port
    }
}
