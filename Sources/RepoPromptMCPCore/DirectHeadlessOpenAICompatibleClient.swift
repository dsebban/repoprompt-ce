import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import MCP

/// Oracle-only OpenAI-compatible `/chat/completions` provider. It has no tools and no workspace
/// access, so it cannot back `agent_run`. The API key is sent only in the `Authorization` header;
/// it is never forwarded to child processes or included in error text.
package struct DirectHeadlessOpenAICompatibleClient {
    struct Configuration: Equatable {
        let endpoint: URL
        let apiKey: String?
    }

    static let baseURLKey = "REPOPROMPT_MCP_HEADLESS_OPENAI_BASE_URL"
    static let apiKeyKey = "REPOPROMPT_MCP_HEADLESS_OPENAI_API_KEY"

    private let session: URLSession

    init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

    /// Reads `REPOPROMPT_MCP_HEADLESS_OPENAI_BASE_URL` (an `http`/`https` API root such as
    /// `https://api.openai.com/v1`) and the optional `REPOPROMPT_MCP_HEADLESS_OPENAI_API_KEY`.
    static func configuration(
        from environment: [String: String]
    ) -> (configuration: Configuration?, unavailableReason: String?) {
        let raw = environment[baseURLKey]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else {
            return (nil, "OpenAI-compatible provider is not configured; set \(baseURLKey) in the repoprompt-mcp process environment.")
        }
        var base = raw
        while base.hasSuffix("/") {
            base.removeLast()
        }
        guard let url = URL(string: base + "/chat/completions"),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host?.isEmpty == false
        else {
            return (nil, "\(baseURLKey) is not a valid http(s) URL.")
        }
        let key = environment[apiKeyKey]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (Configuration(endpoint: url, apiKey: key?.isEmpty == false ? key : nil), nil)
    }

    static func makeRequest(configuration: Configuration, model: String, message: String) throws -> URLRequest {
        var request = URLRequest(url: configuration.endpoint, timeoutInterval: 600)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey = configuration.apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": [["role": "user", "content": message]]
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
                ?? String(decoding: data.prefix(500), as: UTF8.self)
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
        message: String
    ) async throws -> DirectHeadlessProviderCoordinator.TurnOutput {
        let request = try Self.makeRequest(configuration: configuration, model: model, message: message)
        let box = DataTaskBox()
        let (data, statusCode): (Data, Int) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Completion-handler API: the async URLSession overloads are not on every corelibs release.
                box.start(session.dataTask(with: request) { data, response, error in
                    if let error {
                        continuation.resume(
                            throwing: (error as? URLError)?.code == .cancelled
                                ? CancellationError()
                                : Self.error("request failed: \(error.localizedDescription)", configuration: configuration)
                        )
                    } else if let response = response as? HTTPURLResponse {
                        continuation.resume(returning: (data ?? Data(), response.statusCode))
                    } else {
                        continuation.resume(throwing: Self.error("returned a non-HTTP response", configuration: configuration))
                    }
                })
            }
        } onCancel: {
            box.cancel()
        }
        return try Self.parseResponse(data: data, statusCode: statusCode, configuration: configuration)
    }

    /// Servers sometimes echo the credential they rejected, so it is redacted from every message.
    private static func error(_ detail: String, configuration: Configuration) -> MCPError {
        var text = "openaiCompatible \(detail)"
        if let apiKey = configuration.apiKey {
            text = text.replacingOccurrences(of: apiKey, with: "[redacted]")
        }
        return MCPError.internalError(text)
    }
}

/// Holds the in-flight task so cancellation that races `start` still cancels it.
private final class DataTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var isCancelled = false

    func start(_ task: URLSessionDataTask) {
        lock.lock()
        self.task = task
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
}
