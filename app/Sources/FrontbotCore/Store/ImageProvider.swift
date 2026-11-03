import Foundation

/// Genera una imagen a partir de un prompt. Hoy solo OpenAI; la UI no depende del proveedor.
public protocol ImageProvider: Sendable {
    func generate(prompt: String, size: ImageSize) async throws -> Data
}

public typealias ImageHTTP = @Sendable (URLRequest) async throws -> (Data, URLResponse)

/// API de imágenes de OpenAI con la key del llavero (la misma de Codex).
public struct OpenAIImageProvider: ImageProvider {
    public static let model = "gpt-image-1"
    static let endpoint = URL(string: "https://api.openai.com/v1/images/generations")!

    let apiKey: String
    let http: ImageHTTP

    public init(apiKey: String, http: @escaping ImageHTTP = { try await URLSession.shared.data(for: $0) }) {
        self.apiKey = apiKey
        self.http = http
    }

    public func generate(prompt: String, size: ImageSize) async throws -> Data {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 180) // generar una imagen tarda
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["model": Self.model, "prompt": prompt, "size": size.openAIValue, "n": 1]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await http(request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = (json?["error"] as? [String: Any])?["message"] as? String ?? "HTTP \(status)"
            throw ValidationError(String(localized: "OpenAI no generó la imagen: \(message)"))
        }
        guard let first = (json?["data"] as? [[String: Any]])?.first, let b64 = first["b64_json"] as? String,
              let image = Data(base64Encoded: b64) else {
            throw ValidationError(String(localized: "OpenAI no devolvió ninguna imagen."))
        }
        return image
    }
}
