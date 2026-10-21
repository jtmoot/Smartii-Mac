import Foundation

// MARK: - Provider registry model

/// Static metadata describing a single AI provider and the models it exposes.
struct ProviderInfo {
    let id: String
    let label: String
    let tier: String
    let defaultModel: String
    let models: [String]
    let keyURL: String
    let instructions: String
}

/// A user-facing error carrying a human-readable message.
enum SmartiiError: Error, LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self {
        case .message(let m): return m
        }
    }
}

// MARK: - Providers

enum Providers {

    /// The full provider registry, in display order:
    /// gemini, groq, openrouter, huggingface, anthropic, openai, perplexity.
    static let all: [ProviderInfo] = [
        ProviderInfo(
            id: "gemini",
            label: "Google Gemini",
            tier: "free",
            defaultModel: "gemini-2.0-flash",
            models: [
                "gemini-2.0-flash",
                "gemini-2.5-flash",
                "gemini-2.5-pro",
                "gemini-1.5-flash",
                "gemini-1.5-pro",
            ],
            keyURL: "https://aistudio.google.com/app/apikey",
            instructions: "Free API key from Google AI Studio. Every Gemini model can read screenshots."
        ),
        ProviderInfo(
            id: "groq",
            label: "Groq",
            tier: "free",
            defaultModel: "llama-3.3-70b-versatile",
            models: [
                "llama-3.3-70b-versatile",
                "llama-3.1-8b-instant",
                "meta-llama/llama-4-scout-17b-16e-instruct",
            ],
            keyURL: "https://console.groq.com/keys",
            instructions: "Fast, free inference. Screenshots are routed to Llama 4 Scout (the vision model)."
        ),
        ProviderInfo(
            id: "openrouter",
            label: "OpenRouter",
            tier: "mixed",
            defaultModel: "nvidia/nemotron-3-super-120b-a12b:free",
            models: [
                "nvidia/nemotron-3-super-120b-a12b:free",
                "qwen/qwen3-coder:free",
                "meta-llama/llama-3.3-70b-instruct:free",
                "openai/gpt-oss-120b:free",
                "z-ai/glm-4.5-air:free",
                "google/gemma-4-31b-it:free",
                "moonshotai/kimi-k2.6:free",
                "nvidia/nemotron-nano-12b-v2-vl:free",
                "anthropic/claude-3.5-sonnet",
                "openai/gpt-4o",
            ],
            keyURL: "https://openrouter.ai/keys",
            instructions: "One key for many models. Default is NVIDIA Nemotron 3 Super (free, 1M context); any ':free' model costs nothing. Screenshots auto-use a free vision model (Gemma 4 / Kimi)."
        ),
        ProviderInfo(
            id: "huggingface",
            label: "Hugging Face",
            tier: "free",
            defaultModel: "meta-llama/Llama-3.3-70B-Instruct",
            models: [
                "meta-llama/Llama-3.3-70B-Instruct",
                "Qwen/Qwen2.5-72B-Instruct",
            ],
            keyURL: "https://huggingface.co/settings/tokens",
            instructions: "Free inference API. Text only — these models cannot read screenshots."
        ),
        ProviderInfo(
            id: "anthropic",
            label: "Anthropic Claude",
            tier: "paid",
            defaultModel: "claude-opus-5-5",
            models: [
                "claude-fable-5-1",
                "claude-opus-5-5",
                "claude-sonnet-5-5",
                "claude-haiku-5-5",
            ],
            keyURL: "https://console.anthropic.com/settings/keys",
            instructions: "Paid API key. Every Claude model can read screenshots."
        ),
        ProviderInfo(
            id: "openai",
            label: "OpenAI",
            tier: "paid",
            defaultModel: "gpt-4o",
            models: [
                "gpt-4o",
                "gpt-4o-mini",
                "gpt-4-turbo",
                "o1-mini",
            ],
            keyURL: "https://platform.openai.com/api-keys",
            instructions: "Paid API key. Screenshots are routed to a GPT-4o vision model."
        ),
        ProviderInfo(
            id: "perplexity",
            label: "Perplexity",
            tier: "paid",
            defaultModel: "sonar",
            models: [
                "sonar",
                "sonar-pro",
                "sonar-reasoning",
            ],
            keyURL: "https://www.perplexity.ai/settings/api",
            instructions: "Paid API key with live web search. Text only — cannot read screenshots."
        ),
        ProviderInfo(
            id: "ollama",
            label: "Ollama (local)",
            tier: "local",
            defaultModel: "llama3.2",
            models: [
                "llama3.2",
                "qwen2.5",
                "llava",
            ],
            keyURL: "https://ollama.com/download",
            instructions: "Runs models locally — no API key or internet needed. Install Ollama and pull a model. The llava model can read screenshots."
        ),
    ]

    /// Look up provider metadata by id.
    static func info(_ id: String) -> ProviderInfo? {
        all.first { $0.id == id }
    }

    // MARK: - Shared URLSession (request timeouts)

    /// A shared session with a ~60s per-request timeout, used by both the
    /// blocking `call(...)` path and the streaming `stream(...)` path. A single
    /// session is reused so connection pooling and SSE both benefit from the
    /// same configuration.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    /// Whether a provider runs locally and therefore needs no API key.
    private static func isLocal(_ providerId: String) -> Bool {
        providerId == "ollama"
    }

    /// The key actually sent on the wire. Local providers (Ollama) accept any
    /// bearer, so an empty user key is replaced with a harmless placeholder.
    private static func wireKey(for providerId: String, userKey: String) -> String {
        if isLocal(providerId) {
            return userKey.isEmpty ? "ollama" : userKey
        }
        return userKey
    }

    // MARK: - Data URL helper

    /// Splits a data URL of the form "data:<mime>;base64,<payload>" into its
    /// MIME type and the raw base64 payload (without the "data:" prefix).
    /// Returns nil if the string is not a well-formed data URL.
    private static func splitDataURL(_ dataURL: String) -> (mime: String, base64: String)? {
        // mime is the substring between "data:" and the first ";".
        guard dataURL.hasPrefix("data:") else { return nil }
        guard let semicolon = dataURL.firstIndex(of: ";") else { return nil }
        guard let comma = dataURL.firstIndex(of: ",") else { return nil }
        let mimeStart = dataURL.index(dataURL.startIndex, offsetBy: 5) // after "data:"
        guard mimeStart <= semicolon else { return nil }
        let mime = String(dataURL[mimeStart..<semicolon])
        // base64 is everything after the comma.
        let base64 = String(dataURL[dataURL.index(after: comma)...])
        if mime.isEmpty || base64.isEmpty { return nil }
        return (mime, base64)
    }

    // MARK: - Networking helper

    /// Performs the request and returns the response body. Throws
    /// SmartiiError.message on transport failure or non-2xx status (using the
    /// server's error text when parseable, otherwise "HTTP <code>").
    private static func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SmartiiError.message(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw SmartiiError.message("No HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            throw SmartiiError.message(serverErrorText(from: data) ?? "HTTP \(http.statusCode)")
        }
        return data
    }

    /// Best-effort extraction of a human-readable error message from a server
    /// error body. Handles the common shapes used by the supported providers.
    private static func serverErrorText(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            // Some providers return a bare string body.
            let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (raw?.isEmpty == false) ? raw : nil
        }
        if let obj = json as? [String: Any] {
            // {"error": {"message": "..."}} (OpenAI / Groq / OpenRouter / Gemini)
            if let err = obj["error"] as? [String: Any], let msg = err["message"] as? String {
                return msg
            }
            // {"error": "..."} (Hugging Face, some others)
            if let msg = obj["error"] as? String {
                return msg
            }
            // {"message": "..."} (Anthropic-style top-level message)
            if let msg = obj["message"] as? String {
                return msg
            }
            // {"detail": "..."} (Perplexity / FastAPI-style)
            if let msg = obj["detail"] as? String {
                return msg
            }
        }
        return nil
    }

    /// Serializes a JSON body, wrapping failures as SmartiiError.
    private static func serialize(_ body: [String: Any]) throws -> Data {
        do {
            return try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw SmartiiError.message("Failed to encode request: \(error.localizedDescription)")
        }
    }

    /// Parses a JSON response into a dictionary, throwing on malformed bodies.
    private static func parseObject(_ data: Data) throws -> [String: Any] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SmartiiError.message("Unexpected response from provider")
        }
        return obj
    }

    // MARK: - Dispatch

    /// Calls the given provider with the prompt and (optionally) an attached
    /// screenshot as a data URL. Performs vision auto-routing per provider and
    /// returns the model's text answer.
    static func call(
        providerId: String,
        apiKey: String,
        prompt: String,
        imageDataURL: String?,
        model: String?
    ) async throws -> String {
        guard let info = info(providerId) else {
            throw SmartiiError.message("Unknown provider \"\(providerId)\".")
        }

        var trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        // Local providers (Ollama) need no key; an empty/placeholder key is OK.
        if isLocal(providerId) {
            trimmedKey = wireKey(for: providerId, userKey: trimmedKey)
        } else {
            guard !trimmedKey.isEmpty else {
                throw SmartiiError.message("No API key set for \(info.label). Add one in Smartii settings.")
            }
        }

        // Resolve the model: caller-supplied (non-empty) else the provider default.
        let requested = (model?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
        let chosenModel = requested ?? info.defaultModel

        // Decode the screenshot once if present.
        var image: (mime: String, base64: String)?
        if let dataURL = imageDataURL {
            guard let parts = splitDataURL(dataURL) else {
                throw SmartiiError.message("Invalid screenshot data.")
            }
            image = parts
        }

        switch providerId {
        case "gemini":
            return try await callGemini(apiKey: trimmedKey, prompt: prompt, image: image, model: chosenModel)
        case "groq":
            // Vision: only Llama 4 Scout supports images on Groq.
            let model = image == nil ? chosenModel : "meta-llama/llama-4-scout-17b-16e-instruct"
            return try await callOpenAIChat(
                endpoint: "https://api.groq.com/openai/v1/chat/completions",
                apiKey: trimmedKey, prompt: prompt, image: image, model: model, extraHeaders: [:]
            )
        case "openrouter":
            // Vision fallback to a free Gemini vision model.
            let model = image == nil ? chosenModel : "google/gemma-4-31b-it:free"
            return try await callOpenAIChat(
                endpoint: "https://openrouter.ai/api/v1/chat/completions",
                apiKey: trimmedKey, prompt: prompt, image: image, model: model,
                extraHeaders: [
                    "HTTP-Referer": "https://github.com/platret/Smartii-Mac",
                    "X-Title": "Smartii",
                ]
            )
        case "openai":
            // Vision: route to a GPT-4o vision model when the chosen one can't see.
            let visionModels: Set<String> = ["gpt-4o", "gpt-4o-mini", "gpt-4-turbo"]
            let model = (image == nil || visionModels.contains(chosenModel)) ? chosenModel : "gpt-4o-mini"
            return try await callOpenAIChat(
                endpoint: "https://api.openai.com/v1/chat/completions",
                apiKey: trimmedKey, prompt: prompt, image: image, model: model, extraHeaders: [:]
            )
        case "anthropic":
            return try await callAnthropic(apiKey: trimmedKey, prompt: prompt, image: image, model: chosenModel)
        case "perplexity":
            if image != nil {
                throw SmartiiError.message("\(info.label) can't read images. Switch to Gemini or Groq in Smartii settings.")
            }
            return try await callPerplexity(apiKey: trimmedKey, prompt: prompt, model: chosenModel)
        case "huggingface":
            if image != nil {
                throw SmartiiError.message("\(info.label) can't read images. Switch to Gemini or Groq in Smartii settings.")
            }
            return try await callHuggingFace(apiKey: trimmedKey, prompt: prompt, model: chosenModel)
        case "ollama":
            // Vision: only llava can see; route screenshots to it.
            let model = image == nil ? chosenModel : "llava"
            return try await callOpenAIChat(
                endpoint: "http://localhost:11434/v1/chat/completions",
                apiKey: trimmedKey, prompt: prompt, image: image, model: model, extraHeaders: [:]
            )
        default:
            throw SmartiiError.message("Unsupported provider \"\(providerId)\".")
        }
    }

    // MARK: - Streaming dispatch

    /// Streams the answer for the given provider, invoking `onDelta` with each
    /// text chunk as it arrives. The caller is responsible for hopping to the
    /// MainActor inside `onDelta` if it touches UI.
    ///
    /// Behavior:
    /// - OpenAI-compatible families (openai / groq / openrouter / ollama),
    ///   Gemini, and Anthropic stream natively via SSE.
    /// - Perplexity and Hugging Face have no streaming path here, so they fall
    ///   back to `call(...)` and emit the entire answer as a single delta.
    /// - Vision auto-routing matches `call(...)` exactly.
    /// - Honors Task cancellation: throws `CancellationError` if the surrounding
    ///   Task is cancelled before or during streaming.
    static func stream(
        providerId: String,
        apiKey: String,
        prompt: String,
        imageDataURL: String?,
        model: String?,
        onDelta: @escaping @Sendable (String) -> Void
    ) async throws {
        guard let info = info(providerId) else {
            throw SmartiiError.message("Unknown provider \"\(providerId)\".")
        }

        try Task.checkCancellation()

        var trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if isLocal(providerId) {
            trimmedKey = wireKey(for: providerId, userKey: trimmedKey)
        } else {
            guard !trimmedKey.isEmpty else {
                throw SmartiiError.message("No API key set for \(info.label). Add one in Smartii settings.")
            }
        }

        // Resolve the model: caller-supplied (non-empty) else the provider default.
        let requested = (model?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
        let chosenModel = requested ?? info.defaultModel

        // Decode the screenshot once if present.
        var image: (mime: String, base64: String)?
        if let dataURL = imageDataURL {
            guard let parts = splitDataURL(dataURL) else {
                throw SmartiiError.message("Invalid screenshot data.")
            }
            image = parts
        }

        switch providerId {
        case "gemini":
            try await streamGemini(apiKey: trimmedKey, prompt: prompt, image: image, model: chosenModel, onDelta: onDelta)

        case "groq":
            let m = image == nil ? chosenModel : "meta-llama/llama-4-scout-17b-16e-instruct"
            try await streamOpenAIChat(
                endpoint: "https://api.groq.com/openai/v1/chat/completions",
                apiKey: trimmedKey, prompt: prompt, image: image, model: m, extraHeaders: [:], onDelta: onDelta
            )

        case "openrouter":
            let m = image == nil ? chosenModel : "google/gemma-4-31b-it:free"
            try await streamOpenAIChat(
                endpoint: "https://openrouter.ai/api/v1/chat/completions",
                apiKey: trimmedKey, prompt: prompt, image: image, model: m,
                extraHeaders: [
                    "HTTP-Referer": "https://github.com/platret/Smartii-Mac",
                    "X-Title": "Smartii",
                ],
                onDelta: onDelta
            )

        case "openai":
            let visionModels: Set<String> = ["gpt-4o", "gpt-4o-mini", "gpt-4-turbo"]
            let m = (image == nil || visionModels.contains(chosenModel)) ? chosenModel : "gpt-4o-mini"
            try await streamOpenAIChat(
                endpoint: "https://api.openai.com/v1/chat/completions",
                apiKey: trimmedKey, prompt: prompt, image: image, model: m, extraHeaders: [:], onDelta: onDelta
            )

        case "ollama":
            let m = image == nil ? chosenModel : "llava"
            try await streamOpenAIChat(
                endpoint: "http://localhost:11434/v1/chat/completions",
                apiKey: trimmedKey, prompt: prompt, image: image, model: m, extraHeaders: [:], onDelta: onDelta
            )

        case "anthropic":
            try await streamAnthropic(apiKey: trimmedKey, prompt: prompt, image: image, model: chosenModel, onDelta: onDelta)

        case "perplexity":
            // No streaming path: fall back to the blocking call and emit once.
            if image != nil {
                throw SmartiiError.message("\(info.label) can't read images. Switch to Gemini or Groq in Smartii settings.")
            }
            let answer = try await call(
                providerId: providerId, apiKey: apiKey, prompt: prompt, imageDataURL: imageDataURL, model: model
            )
            try Task.checkCancellation()
            onDelta(answer)

        case "huggingface":
            if image != nil {
                throw SmartiiError.message("\(info.label) can't read images. Switch to Gemini or Groq in Smartii settings.")
            }
            let answer = try await call(
                providerId: providerId, apiKey: apiKey, prompt: prompt, imageDataURL: imageDataURL, model: model
            )
            try Task.checkCancellation()
            onDelta(answer)

        default:
            throw SmartiiError.message("Unsupported provider \"\(providerId)\".")
        }
    }

    // MARK: - SSE helpers

    /// Issues `request` and iterates its response as a byte stream, yielding one
    /// trimmed line at a time. Validates the HTTP status (reading the body for an
    /// error message on failure) and checks Task cancellation on every line.
    private static func sseLines(
        _ request: URLRequest,
        _ handleLine: (String) throws -> Void
    ) async throws {
        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw SmartiiError.message(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw SmartiiError.message("No HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            // Drain the error body so we can surface a useful message.
            var collected = Data()
            for try await byte in bytes { collected.append(byte) }
            throw SmartiiError.message(serverErrorText(from: collected) ?? "HTTP \(http.statusCode)")
        }

        do {
            for try await line in bytes.lines {
                try Task.checkCancellation()
                try handleLine(line)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let e as SmartiiError {
            throw e
        } catch {
            if (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw SmartiiError.message(error.localizedDescription)
        }
    }

    /// Extracts the JSON payload from an SSE "data:" line, returning nil for
    /// blank lines, comments, the "[DONE]" sentinel, or non-data lines.
    private static func sseData(from line: String) -> [String: Any]? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        if payload.isEmpty || payload == "[DONE]" { return nil }
        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    // MARK: - OpenAI-compatible streaming (openai / groq / openrouter / ollama)

    private static func streamOpenAIChat(
        endpoint: String, apiKey: String, prompt: String,
        image: (mime: String, base64: String)?, model: String,
        extraHeaders: [String: String], onDelta: @escaping @Sendable (String) -> Void
    ) async throws {
        guard let url = URL(string: endpoint) else {
            throw SmartiiError.message("Invalid request URL.")
        }

        let content: Any
        if let image = image {
            content = [
                ["type": "text", "text": prompt],
                ["type": "image_url", "image_url": ["url": "data:\(image.mime);base64,\(image.base64)"]],
            ] as [[String: Any]]
        } else {
            content = prompt
        }

        var body = anthropicBaseBody(model: model)
        body["stream"] = true
        body["messages"] = [["role": "user", "content": content]]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        for (k, v) in extraHeaders { request.setValue(v, forHTTPHeaderField: k) }
        request.httpBody = try serialize(body)

        try await sseLines(request) { line in
            guard let obj = sseData(from: line) else { return }
            // An error can arrive mid-stream as {"error": {...}}.
            if let err = obj["error"] as? [String: Any], let msg = err["message"] as? String {
                throw SmartiiError.message(msg)
            }
            guard let choices = obj["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let delta = first["delta"] as? [String: Any],
                  let text = delta["content"] as? String, !text.isEmpty
            else { return }
            onDelta(text)
        }
    }

    // MARK: - Gemini streaming

    private static func streamGemini(
        apiKey: String, prompt: String, image: (mime: String, base64: String)?,
        model: String, onDelta: @escaping @Sendable (String) -> Void
    ) async throws {
        guard let encodedKey = apiKey.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):streamGenerateContent?alt=sse&key=\(encodedKey)")
        else {
            throw SmartiiError.message("Invalid Gemini request URL.")
        }

        var parts: [[String: Any]] = [["text": prompt]]
        if let image = image {
            parts.append(["inline_data": ["mime_type": image.mime, "data": image.base64]])
        }
        let body: [String: Any] = [
            "contents": [["role": "user", "parts": parts]]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try serialize(body)

        try await sseLines(request) { line in
            guard let obj = sseData(from: line) else { return }
            if let err = obj["error"] as? [String: Any], let msg = err["message"] as? String {
                throw SmartiiError.message(msg)
            }
            guard let candidates = obj["candidates"] as? [[String: Any]],
                  let first = candidates.first,
                  let content = first["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]]
            else { return }
            let text = parts.compactMap { $0["text"] as? String }.joined()
            if !text.isEmpty { onDelta(text) }
        }
    }

    // MARK: - Anthropic request shape

    /// Shared Claude request body: adaptive thinking at high effort so the model
    /// reasons before it answers (the visible reply stays short), a generous output
    /// cap, and Anthropic's server-side refusal fallback where the model supports it.
    private static func anthropicBaseBody(model: String) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "thinking": ["type": "adaptive"],
            "output_config": ["effort": "high"],
        ]
        if anthropicSupportsFallbacks(model) { body["fallbacks"] = "default" }
        return body
    }

    /// `fallbacks: "default"` is accepted on the Fable 5.x, Opus 5.x and Sonnet 5.5 lines.
    private static func anthropicSupportsFallbacks(_ model: String) -> Bool {
        model.hasPrefix("claude-fable-5") || model.hasPrefix("claude-opus-5") || model.hasPrefix("claude-sonnet-5-5")
    }

    private static func anthropicRefusalMessage(category: String?) -> String {
        let reason = category.map { " (\($0))" } ?? ""
        return "Claude declined this request\(reason)."
    }

    // MARK: - Anthropic streaming

    private static func streamAnthropic(
        apiKey: String, prompt: String, image: (mime: String, base64: String)?,
        model: String, onDelta: @escaping @Sendable (String) -> Void
    ) async throws {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw SmartiiError.message("Invalid Anthropic request URL.")
        }

        let content: [[String: Any]]
        if let image = image {
            content = [
                ["type": "image", "source": ["type": "base64", "media_type": image.mime, "data": image.base64]],
                ["type": "text", "text": prompt],
            ]
        } else {
            content = [["type": "text", "text": prompt]]
        }

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 2048,
            "stream": true,
            "messages": [["role": "user", "content": content]],
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("true", forHTTPHeaderField: "anthropic-dangerous-direct-browser-access")
        if anthropicSupportsFallbacks(model) {
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try serialize(body)

        try await sseLines(request) { line in
            guard let obj = sseData(from: line) else { return }
            // Anthropic surfaces errors as an {"type":"error","error":{...}} event.
            if let type = obj["type"] as? String, type == "error",
               let err = obj["error"] as? [String: Any], let msg = err["message"] as? String {
                throw SmartiiError.message(msg)
            }
            // A safety-classifier decline ends the stream with stop_reason "refusal".
            if let type = obj["type"] as? String, type == "message_delta",
               let md = obj["delta"] as? [String: Any],
               let stop = md["stop_reason"] as? String, stop == "refusal" {
                throw SmartiiError.message(anthropicRefusalMessage(category: nil))
            }
            // We only care about content_block_delta → delta.text.
            guard let type = obj["type"] as? String, type == "content_block_delta",
                  let delta = obj["delta"] as? [String: Any],
                  let text = delta["text"] as? String, !text.isEmpty
            else { return }
            onDelta(text)
        }
    }

    // MARK: - Gemini

    private static func callGemini(
        apiKey: String, prompt: String, image: (mime: String, base64: String)?, model: String
    ) async throws -> String {
        // Key is passed as a query parameter on the generateContent endpoint.
        guard let encodedKey = apiKey.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(encodedKey)")
        else {
            throw SmartiiError.message("Invalid Gemini request URL.")
        }

        var parts: [[String: Any]] = [["text": prompt]]
        if let image = image {
            parts.append(["inline_data": ["mime_type": image.mime, "data": image.base64]])
        }
        let body: [String: Any] = [
            "contents": [["role": "user", "parts": parts]]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try serialize(body)

        let data = try await send(request)
        let obj = try parseObject(data)

        // candidates[0].content.parts[].text joined.
        guard let candidates = obj["candidates"] as? [[String: Any]],
              let first = candidates.first,
              let content = first["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]]
        else {
            throw SmartiiError.message(serverErrorText(from: data) ?? "Gemini returned no answer.")
        }
        let text = parts.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else {
            throw SmartiiError.message("Gemini returned an empty answer.")
        }
        return text
    }

    // MARK: - OpenAI-compatible chat (groq / openrouter / openai)

    private static func callOpenAIChat(
        endpoint: String, apiKey: String, prompt: String,
        image: (mime: String, base64: String)?, model: String, extraHeaders: [String: String]
    ) async throws -> String {
        guard let url = URL(string: endpoint) else {
            throw SmartiiError.message("Invalid request URL.")
        }

        // content is the plain prompt, or a multimodal array when an image is present.
        let content: Any
        if let image = image {
            content = [
                ["type": "text", "text": prompt],
                ["type": "image_url", "image_url": ["url": "data:\(image.mime);base64,\(image.base64)"]],
            ] as [[String: Any]]
        } else {
            content = prompt
        }

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 2048,
            "messages": [["role": "user", "content": content]],
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        for (k, v) in extraHeaders { request.setValue(v, forHTTPHeaderField: k) }
        request.httpBody = try serialize(body)

        let data = try await send(request)
        let obj = try parseObject(data)

        // choices[0].message.content
        guard let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let text = message["content"] as? String, !text.isEmpty
        else {
            throw SmartiiError.message(serverErrorText(from: data) ?? "Provider returned no answer.")
        }
        return text
    }

    // MARK: - Anthropic

    private static func callAnthropic(
        apiKey: String, prompt: String, image: (mime: String, base64: String)?, model: String
    ) async throws -> String {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw SmartiiError.message("Invalid Anthropic request URL.")
        }

        // content is a typed-block array; image block precedes the text block.
        let content: [[String: Any]]
        if let image = image {
            content = [
                ["type": "image", "source": ["type": "base64", "media_type": image.mime, "data": image.base64]],
                ["type": "text", "text": prompt],
            ]
        } else {
            content = [["type": "text", "text": prompt]]
        }

        var body = anthropicBaseBody(model: model)
        body["messages"] = [["role": "user", "content": content]]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("true", forHTTPHeaderField: "anthropic-dangerous-direct-browser-access")
        if anthropicSupportsFallbacks(model) {
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = try serialize(body)

        let data = try await send(request)
        let obj = try parseObject(data)

        if let stop = obj["stop_reason"] as? String, stop == "refusal" {
            let category = (obj["stop_details"] as? [String: Any])?["category"] as? String
            throw SmartiiError.message(anthropicRefusalMessage(category: category))
        }

        // content[].text joined.
        guard let blocks = obj["content"] as? [[String: Any]] else {
            throw SmartiiError.message(serverErrorText(from: data) ?? "Claude returned no answer.")
        }
        let text = blocks.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else {
            throw SmartiiError.message("Claude returned an empty answer.")
        }
        return text
    }

    // MARK: - Perplexity

    private static func callPerplexity(apiKey: String, prompt: String, model: String) async throws -> String {
        guard let url = URL(string: "https://api.perplexity.ai/chat/completions") else {
            throw SmartiiError.message("Invalid Perplexity request URL.")
        }

        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": prompt]],
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try serialize(body)

        let data = try await send(request)
        let obj = try parseObject(data)

        // choices[0].message.content
        guard let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let text = message["content"] as? String, !text.isEmpty
        else {
            throw SmartiiError.message(serverErrorText(from: data) ?? "Perplexity returned no answer.")
        }
        return text
    }

    // MARK: - Hugging Face

    private static func callHuggingFace(apiKey: String, prompt: String, model: String) async throws -> String {
        guard let url = URL(string: "https://api-inference.huggingface.co/models/\(model)") else {
            throw SmartiiError.message("Invalid Hugging Face request URL.")
        }

        let body: [String: Any] = [
            "inputs": prompt,
            "parameters": ["max_new_tokens": 1024, "return_full_text": false],
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try serialize(body)

        let data = try await send(request)

        // Response is either an array of objects or a single object.
        let json = try? JSONSerialization.jsonObject(with: data)
        if let arr = json as? [[String: Any]], let text = arr.first?["generated_text"] as? String, !text.isEmpty {
            return text
        }
        if let obj = json as? [String: Any], let text = obj["generated_text"] as? String, !text.isEmpty {
            return text
        }
        throw SmartiiError.message(serverErrorText(from: data) ?? "Hugging Face returned no answer.")
    }
}
