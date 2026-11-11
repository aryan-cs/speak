import Foundation
import LLMkit
import SwiftData

struct GroqProvider: SegmentedCloudProvider {
    let modelProvider: ModelProvider = .groq
    let providerKey: String = "Groq"
    let languageCodes: [String]? = nil
    let includesAutoDetect: Bool = false

    private static let baseURL = URL(string: "https://api.groq.com/openai")!
    private static let retryableStatusCodes: Set<Int> = [429, 500, 502, 503, 504]
    private static let maximumRetries = 2

    var models: [CloudModel] {
        [
            CloudModel(
                name: "whisper-large-v3-turbo",
                displayName: "Whisper Large v3 Turbo",
                description: "Whisper Large v3 Turbo model with Groq's lightning-speed inference",
                provider: .groq,
                isMultilingual: true,
                supportedLanguages: LanguageDictionary.forProvider(isMultilingual: true, provider: .groq)
            )
        ]
    }

    func transcribe(
        audioData: Data, fileName: String, apiKey: String, model: String, language: String?,
        customVocabulary: [String], timeout: TimeInterval
    ) async throws -> String {
        return try await OpenAITranscriptionClient.transcribe(
            baseURL: Self.baseURL,
            audioData: audioData,
            fileName: fileName,
            apiKey: apiKey,
            model: model,
            language: language,
            timeout: timeout
        )
    }

    /// The same request as `transcribe`, asking for `verbose_json` so each line comes with its
    /// time span. Retries like LLMkit's client: twice on network errors and 429/5xx, after 1 s and 2 s.
    func transcribeSegments(
        audioData: Data, fileName: String, apiKey: String, model: String, language: String?,
        timeout: TimeInterval
    ) async throws -> SegmentedTranscript {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMKitError.missingAPIKey
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }
        func field(_ name: String, _ value: String) {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n")
        append("Content-Type: audio/wav\r\n\r\n")
        body.append(audioData)
        append("\r\n")
        field("model", model)
        if let language, !language.isEmpty {
            field("language", language)
        }
        field("response_format", "verbose_json")
        field("timestamp_granularities[]", "segment")
        field("temperature", "0")
        append("--\(boundary)--\r\n")

        var request = URLRequest(url: Self.baseURL.appendingPathComponent("v1/audio/transcriptions"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await Self.upload(request, body: body, timeout: timeout)
        guard let http = response as? HTTPURLResponse else {
            throw LLMKitError.networkError("No HTTP response received.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LLMKitError.httpError(
                statusCode: http.statusCode, message: String(data: data, encoding: .utf8) ?? "No error details")
        }
        guard let transcript = try? JSONDecoder().decode(SegmentedTranscript.self, from: data) else {
            throw LLMKitError.noResultReturned
        }
        return transcript
    }

    private static func upload(_ request: URLRequest, body: Data, timeout: TimeInterval) async throws
        -> (Data, URLResponse)
    {
        var lastError: (any Error)?
        for attempt in 0...maximumRetries {
            if attempt > 0 {
                try await Task.sleep(nanoseconds: UInt64(1 << (attempt - 1)) * 1_000_000_000)
            }
            // Ephemeral session per request: QUIC bulk uploads blackhole behind some VPNs.
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = timeout
            configuration.timeoutIntervalForResource = timeout
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
            let session = URLSession(configuration: configuration)
            defer { session.finishTasksAndInvalidate() }

            do {
                let (data, response) = try await session.upload(for: request, from: body)
                if let http = response as? HTTPURLResponse, retryableStatusCodes.contains(http.statusCode),
                    attempt < maximumRetries
                {
                    lastError = LLMKitError.httpError(
                        statusCode: http.statusCode, message: String(data: data, encoding: .utf8) ?? "")
                    continue
                }
                return (data, response)
            } catch let error as NSError where error.domain == NSURLErrorDomain && error.code == NSURLErrorTimedOut {
                throw LLMKitError.timeout
            } catch {
                lastError = error
            }
        }
        throw lastError ?? LLMKitError.networkError("Request failed after \(maximumRetries + 1) attempts")
    }

    func makeStreamingProvider(modelContext: ModelContext) -> (any StreamingTranscriptionProvider)? { nil }

    func verifyAPIKey(_ key: String) async -> (isValid: Bool, errorMessage: String?) {
        return await OpenAITranscriptionClient.verifyAPIKey(
            baseURL: Self.baseURL,
            apiKey: key
        )
    }
}
