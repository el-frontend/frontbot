import Foundation

/// Carpeta de trabajo de una conversación: reglas de validación. Debe coincidir con `agent/src/workdir.ts`.
public enum Workdir {
    /// Idéntica a `WORKDIR_ALLOWED_DOMAINS` del sidecar: lista base de red de los comandos.
    public static let defaultNetworkDomains: [String] = [
        "registry.npmjs.org", "*.npmjs.org", "github.com", "*.github.com", "*.githubusercontent.com",
        "cdn.jsdelivr.net", "unpkg.com", "fonts.googleapis.com", "fonts.gstatic.com",
    ]

    /// Nunca se leen ni se escriben, aunque caigan dentro de la carpeta elegida (mismo orden que el sidecar).
    /// El perfil de Frontbot Chrome no se incluye: el sidecar no define ninguno propio.
    public static func alwaysDenied(home: String) -> [String] {
        [".ssh", ".aws", ".gnupg", "Library/Keychains", "Library/Application Support/Frontbot",
         "Library/Application Support/Google/Chrome"].map { home + "/" + $0 }
    }

    // APFS no distingue mayúsculas: `~/.SSH` es `~/.ssh`.
    private static func inside(_ path: String, _ root: String) -> Bool {
        AgentFiles.path(path.lowercased(), isInside: root.lowercased())
    }

    private static func real(_ path: String) -> String { AgentFiles.realPath(path) ?? path }

    /// Devuelve la ruta real de la carpeta o lanza si no sirve como carpeta de trabajo.
    public static func validated(_ path: String, home: String = NSHomeDirectory(), protected: [URL]) throws -> String {
        guard let resolved = AgentFiles.realPath(path), AgentFiles.isDirectory(resolved) else {
            throw ValidationError(String(localized: "\(path) no es una carpeta."))
        }
        let realHome = real(home)
        if resolved == "/" || resolved.lowercased() == realHome.lowercased() {
            throw ValidationError(String(localized: "Elige una carpeta concreta, no toda tu carpeta personal."))
        }
        // Un ancestro de una ruta denegada (p. ej. ~/Library) la dejaría al alcance; una ruta dentro de ella, también.
        let denied = alwaysDenied(home: realHome) + protected.map { real($0.path) }
        if denied.contains(where: { inside($0, resolved) || inside(resolved, $0) }) {
            throw ValidationError(String(localized: "Esa carpeta contiene datos protegidos (claves, llaveros o datos de Frontbot)."))
        }
        return resolved
    }

    /// Carpetas tan amplias que conviene avisar antes de darlas (la app pide confirmación).
    public static func isBroad(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        let p = real(path).lowercased()
        return ["Documents", "Desktop", "Downloads", "Pictures"].contains { p == real(home + "/" + $0).lowercased() }
    }

    /// `host.tld` o `*.host.tld`, en minúsculas. Sin `*` solo, esquemas, rutas ni puertos.
    public static func validatedDomain(_ raw: String) throws -> String {
        let d = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard d.range(of: #"^(\*\.)?[a-z0-9-]+(\.[a-z0-9-]+)+$"#, options: .regularExpression) != nil else {
            throw ValidationError(String(localized: "\"\(raw)\" no es un sitio válido: usa algo como github.com o *.github.com."))
        }
        return d
    }
}
