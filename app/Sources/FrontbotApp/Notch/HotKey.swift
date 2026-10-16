import AppKit
import Carbon.HIToolbox

// Carbon exige un manejador C de nivel superior; el estado vive en globales que solo se tocan en el hilo principal.
private nonisolated(unsafe) var gHandler: EventHandlerRef?
private nonisolated(unsafe) var gOnPress: (() -> Void)?

private func frontbotHotKeyHandler(_: EventHandlerCallRef?, _: EventRef?, _: UnsafeMutableRawPointer?) -> OSStatus {
    MainActor.assumeIsolated { gOnPress?() }
    return noErr
}

/// Atajo global ⌥Espacio vía `RegisterEventHotKey` (no requiere permisos de Accesibilidad).
/// Adaptado de coucou `HotKeyCenter` (MIT, © 2026 Louis Raillé).
@MainActor
final class HotKey {
    static let shared = HotKey()
    private var ref: EventHotKeyRef?
    private(set) var registered = false

    func register(onPress: @escaping @MainActor () -> Void) {
        gOnPress = { MainActor.assumeIsolated { onPress() } }
        if gHandler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), frontbotHotKeyHandler, 1, &spec, nil, &gHandler)
        }
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        let id = EventHotKeyID(signature: OSType(0x46524254), id: 1) // "FRBT"
        // Exclusivo: sin esta opción el registro "funciona" aunque otra app ya tenga ⌥Espacio y nunca nos llega.
        let status = RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey), id, GetApplicationEventTarget(),
                                         OptionBits(kEventHotKeyExclusive), &ref)
        registered = status == noErr
    }
}
