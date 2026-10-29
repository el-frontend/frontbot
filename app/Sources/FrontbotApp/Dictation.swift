import AppKit
import AVFoundation
import Speech

/// Dictado del chat con el reconocimiento de voz de macOS, siempre en el Mac: el audio no sale
/// del equipo ni gasta tokens. Si el idioma no tiene reconocimiento local, no se dicta.
@MainActor
final class Dictation: ObservableObject {
    enum State: Equatable { case idle, starting, listening }

    @Published private(set) var state: State = .idle
    /// Volumen de la voz entre 0 y 1, para la animación del micrófono.
    @Published private(set) var level: Float = 0
    @Published var problem: String?

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var onText: ((String) -> Void)?

    var isActive: Bool { state != .idle }

    func toggle(onText: @escaping (String) -> Void) {
        if isActive { stop() } else { Task { await start(onText: onText) } }
    }

    /// `onText` recibe la transcripción completa de esta sesión cada vez que cambia.
    func start(onText: @escaping (String) -> Void) async {
        guard state == .idle else { return }
        problem = nil
        // Sin estas claves en Info.plist macOS cierra la app al pedir permiso (pasa con `swift run`).
        guard Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil,
              Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil else {
            problem = String(localized: "El dictado solo funciona en la app empaquetada (scripts/build-app.sh).")
            return
        }
        state = .starting
        guard await Self.speechAuthorized() else {
            fail(String(localized: "Frontbot no tiene permiso de reconocimiento de voz."), settings: "Privacy_SpeechRecognition"); return
        }
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            fail(String(localized: "Frontbot no tiene permiso para usar el micrófono."), settings: "Privacy_Microphone"); return
        }
        guard state == .starting else { return } // se detuvo mientras pedía permisos
        guard let recognizer = Self.recognizer(), recognizer.isAvailable else {
            fail(String(localized: "El reconocimiento de voz no está disponible para tu idioma ahora mismo.")); return
        }
        guard recognizer.supportsOnDeviceRecognition else {
            fail(String(localized: "Tu idioma no tiene dictado dentro del Mac. Descárgalo en Ajustes del Sistema › Teclado › Dictado.")); return
        }

        task?.cancel() // la sesión anterior pudo quedar entregando su resultado final
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.requiresOnDeviceRecognition = true

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { fail(String(localized: "No encuentro ningún micrófono.")); return }
        let sink = AudioSink(request: request) { [weak self] level in
            Task { @MainActor in self?.level = level }
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable buffer, _ in sink.append(buffer) }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            fail(String(localized: "No pude abrir el micrófono: \(error.localizedDescription)")); return
        }

        self.request = request
        self.onText = onText
        state = .listening
        // Los callbacks de audio, permisos y reconocimiento llegan en otros hilos: van marcados
        // @Sendable para que no hereden el MainActor (Swift 6 cierra la app si se llaman fuera de él).
        let session = ObjectIdentifier(request)
        task = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil && result == nil
            Task { @MainActor in
                guard let self, let current = self.request, ObjectIdentifier(current) == session else { return }
                if let text { self.onText?(text) }
                if isFinal || failed { self.finish() }
            }
        }
    }

    /// Deja de escuchar; el reconocedor entrega lo que falte y luego se cierra.
    func stop() {
        guard isActive else { return }
        if request == nil { state = .idle; return } // aún pidiendo permisos
        stopAudio()
        request?.endAudio()
        state = .idle
    }

    /// Para y descarta lo que quede por llegar (al enviar el mensaje).
    func cancel() {
        guard isActive else { return }
        task?.cancel()
        finish()
    }

    private func finish() {
        stopAudio()
        task = nil
        request = nil
        onText = nil
        state = .idle
    }

    private func stopAudio() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        level = 0
    }

    private func fail(_ message: String, settings pane: String? = nil) {
        finish()
        problem = message
        if let pane, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func recognizer() -> SFSpeechRecognizer? {
        SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "es-ES"))
    }

    private static func speechAuthorized() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { @Sendable in continuation.resume(returning: $0 == .authorized) }
            }
        default: return false
        }
    }
}

/// Recibe el audio en el hilo de tiempo real del micrófono: lo pasa al reconocedor y mide el volumen.
private final class AudioSink: @unchecked Sendable {
    private let request: SFSpeechAudioBufferRecognitionRequest
    private let onLevel: @Sendable (Float) -> Void
    private var frames = 0

    init(request: SFSpeechAudioBufferRecognitionRequest, onLevel: @escaping @Sendable (Float) -> Void) {
        self.request = request
        self.onLevel = onLevel
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        request.append(buffer)
        frames += 1
        guard frames % 3 == 0, let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += samples[i] * samples[i] }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        // De -50 dB (silencio) a -10 dB (voz alta) → 0…1.
        let db = 20 * log10(max(rms, 1e-6))
        onLevel(min(max((db + 50) / 40, 0), 1))
    }
}
