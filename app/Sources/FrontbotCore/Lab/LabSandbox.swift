import Foundation

/// Ejecuta los scripts del laboratorio sin aprobación del usuario: sin red, leyendo solo el laboratorio del agente,
/// los datasets y sus skills asignados, y escribiendo solo en el tema y en `shared/`.
public struct LabSandbox: Sendable {
    let paths: AppPaths
    let db: AppDatabase
    let sandbox: ScriptSandbox
    let maxAgentBytes: Int

    public init(paths: AppPaths, db: AppDatabase, nodePath: String? = nil, timeout: TimeInterval = 300,
                maxAgentBytes: Int = LabWorkspace.defaultMaxAgentBytes) {
        self.maxAgentBytes = maxAgentBytes
        self.paths = paths
        self.db = db
        self.sandbox = ScriptSandbox(timeout: timeout, nodePath: nodePath)
    }

    public func run(agentId: String, topicId: String, script: String, args: [String]) throws -> ScriptSandbox.Result {
        if script.trimmingCharacters(in: .whitespaces).hasPrefix("dataset:") {
            throw ValidationError("Los datasets no se ejecutan: copia el script a tu tema.")
        }
        let workspace = LabWorkspace(paths: paths, db: db, agentId: agentId, topicId: topicId, maxAgentBytes: maxAgentBytes)
        guard workspace.usedBytes <= maxAgentBytes else {
            throw ValidationError("Tu laboratorio superó el límite de \(maxAgentBytes >= 1_000_000 ? "\(maxAgentBytes / 1_000_000) MB" : "\(maxAgentBytes) bytes"): borra archivos antes de ejecutar scripts.")
        }
        let fm = FileManager.default
        // Las carpetas existen antes de resolver, para que el perfil use sus rutas reales.
        let topic = paths.labTopicDir(agentId, topicId), shared = paths.labSharedDir(agentId)
        for dir in [topic, shared, paths.datasetsDir] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }

        let url = try workspace.resolve(script, forWriting: false)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            throw ValidationError("No existe el script \(script).")
        }
        // La raíz real del tema se calcula tras resolver: así un enlace en el camino no ensancha la sandbox.
        let realTopic = URL(fileURLWithPath: ScriptSandbox.realPath(topic)), realShared = URL(fileURLWithPath: ScriptSandbox.realPath(shared))
        guard LabWorkspace.path(realTopic.path, isInside: ScriptSandbox.realPath(paths.labDir(agentId))),
              LabWorkspace.path(realShared.path, isInside: ScriptSandbox.realPath(paths.labDir(agentId))) else {
            throw ValidationError("Ruta fuera de tu laboratorio: \(script).")
        }

        let skills = try SkillLibrary(db: db, paths: paths).skills(assignedTo: agentId, activeOnly: true)
        var readDirs = [paths.labDir(agentId), paths.datasetsDir] + skills.map { paths.skillDir($0.name) }
        var interpreter: String?
        if url.pathExtension.lowercased() == "py", fm.isExecutableFile(atPath: paths.labVenvPython.path) {
            interpreter = paths.labVenvPython.path
            readDirs.append(paths.labsDir.appendingPathComponent(".venv", isDirectory: true)) // sus paquetes
        }
        return try sandbox.run(script: url.path, args: args, in: realTopic, readDirs: readDirs, writeDirs: [realTopic, realShared], interpreter: interpreter)
    }
}
