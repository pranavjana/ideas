import Foundation

enum StreamEvent {
    case textDelta(String)
    case toolCallDelta(index: Int, id: String?, name: String?, argumentsDelta: String)
    case done
}

struct OpenAIService {
    private static let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

    struct Message {
        let role: String // "system", "user", "assistant", "tool"
        let content: String?
        var toolCallId: String?
        var toolCalls: [[String: Any]]?
        var imageBase64: String?

        init(role: String, content: String) {
            self.role = role
            self.content = content
        }

        init(toolResult: String, toolCallId: String) {
            self.role = "tool"
            self.content = toolResult
            self.toolCallId = toolCallId
        }

        func toDict() -> [String: Any] {
            var dict: [String: Any] = ["role": role]

            if let imageBase64 {
                // Multimodal content array
                var contentArray: [[String: Any]] = []
                if let content, !content.isEmpty {
                    contentArray.append(["type": "text", "text": content])
                }
                let mime: String
                if imageBase64.hasPrefix("/9j/") {
                    mime = "image/jpeg"
                } else if imageBase64.hasPrefix("iVBOR") {
                    mime = "image/png"
                } else if imageBase64.hasPrefix("R0lG") {
                    mime = "image/gif"
                } else if imageBase64.hasPrefix("UklGR") {
                    mime = "image/webp"
                } else {
                    mime = "image/png"
                }
                contentArray.append([
                    "type": "image_url",
                    "image_url": ["url": "data:\(mime);base64,\(imageBase64)"]
                ])
                dict["content"] = contentArray
            } else if let content {
                dict["content"] = content
            }

            if let toolCallId { dict["tool_call_id"] = toolCallId }
            if let toolCalls { dict["tool_calls"] = toolCalls }
            return dict
        }
    }

    /// Streams a chat completion response, yielding text deltas.
    static func streamCompletion(
        apiKey: String,
        model: String = "anthropic/claude-haiku-4.5",
        messages: [Message]
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let stream = streamCompletionWithTools(
                        apiKey: apiKey,
                        model: model,
                        messages: messages,
                        tools: nil
                    )
                    for try await event in stream {
                        if case .textDelta(let text) = event {
                            continuation.yield(text)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Non-streaming completion that returns JSON. Used for tagging/classification.
    static func jsonCompletion(
        apiKey: String,
        model: String = "google/gemini-2.5-flash-lite",
        messages: [Message]
    ) async throws -> [String: Any] {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("ideas-app", forHTTPHeaderField: "X-Title")

        let body: [String: Any] = [
            "model": model,
            "stream": false,
            "response_format": ["type": "json_object"],
            "messages": messages.map { $0.toDict() }
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            let errorBody = String(data: data, encoding: .utf8) ?? ""
            throw OpenAIError.apiError(statusCode: httpResponse.statusCode, message: errorBody)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String,
              let contentData = content.data(using: .utf8),
              let result = try? JSONSerialization.jsonObject(with: contentData) as? [String: Any]
        else {
            throw OpenAIError.apiError(statusCode: 0, message: "failed to parse JSON response")
        }

        return result
    }

    /// Streams a chat completion with tool calling support.
    static func streamCompletionWithTools(
        apiKey: String,
        model: String = "anthropic/claude-haiku-4.5",
        messages: [Message],
        tools: [[String: Any]]?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: endpoint)
                    request.httpMethod = "POST"
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("ideas-app", forHTTPHeaderField: "X-Title")

                    var body: [String: Any] = [
                        "model": model,
                        "stream": true,
                        "messages": messages.map { $0.toDict() }
                    ]
                    if let tools, !tools.isEmpty {
                        body["tools"] = tools
                    }
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (stream, response) = try await URLSession.shared.bytes(for: request)

                    if let httpResponse = response as? HTTPURLResponse {
                        guard (200...299).contains(httpResponse.statusCode) else {
                            var errorBody = ""
                            for try await line in stream.lines {
                                errorBody += line
                            }
                            continuation.finish(throwing: OpenAIError.apiError(
                                statusCode: httpResponse.statusCode,
                                message: errorBody
                            ))
                            return
                        }
                    }

                    // Parse SSE stream
                    for try await line in stream.lines {
                        guard !Task.isCancelled else { break }
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        if payload == "[DONE]" {
                            continuation.yield(.done)
                            break
                        }

                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let choices = json["choices"] as? [[String: Any]],
                              let delta = choices.first?["delta"] as? [String: Any]
                        else { continue }

                        // Text content delta
                        if let content = delta["content"] as? String {
                            continuation.yield(.textDelta(content))
                        }

                        // Tool call deltas
                        if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
                            for tc in toolCalls {
                                let index = tc["index"] as? Int ?? 0
                                let id = tc["id"] as? String
                                let function = tc["function"] as? [String: Any]
                                let name = function?["name"] as? String
                                let argsDelta = function?["arguments"] as? String ?? ""
                                continuation.yield(.toolCallDelta(
                                    index: index,
                                    id: id,
                                    name: name,
                                    argumentsDelta: argsDelta
                                ))
                            }
                        }
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}

enum OpenAIError: LocalizedError {
    case apiError(statusCode: Int, message: String)
    case noAPIKey

    var errorDescription: String? {
        switch self {
        case .apiError(let code, let message):
            if code == 401 { return "invalid api key" }
            if code == 429 { return "rate limited — try again in a moment" }
            return "api error (\(code)): \(message)"
        case .noAPIKey:
            return "add your openrouter api key in settings"
        }
    }
}
