import Foundation

extension Pipe {
    /// Escribir a un pipe cuyo lector murió no debe matar la app con SIGPIPE:
    /// con F_SETNOSIGPIPE la escritura falla con EPIPE y `write(contentsOf:)` lanza.
    func disableSigpipe() {
        _ = fcntl(fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    }
}
