import Foundation

/// Lo que el usuario ve antes de permitir que un agente escriba un archivo.
public struct FileWriteRequest: Equatable, Sendable {
    public let agentName: String
    public let path: String
    public let content: String
    /// Sobrescribe un archivo que ya existe (de `previousSize` bytes).
    public let replaces: Bool
    public let previousSize: Int?
}

extension AgentFiles {
    /// Las carpetas del agente, con los datos de Frontbot siempre vetados.
    public static func forAgent(_ agentId: String, db: AppDatabase, paths: AppPaths) throws -> AgentFiles {
        AgentFiles(folders: try db.folders(agentId: agentId), protected: [paths.root])
    }
}

/// `tool.files_write`: valida la ruta, pide aprobación al usuario y escribe.
public struct FileWriteTool: Sendable {
    let db: AppDatabase
    let paths: AppPaths

    public init(db: AppDatabase, paths: AppPaths) {
        self.db = db
        self.paths = paths
    }

    public func run(params: JSONValue, approve: @Sendable (FileWriteRequest) async -> Bool) async throws -> JSONValue {
        guard let agentId = params["agent_id"]?.stringValue, let agent = try db.agent(id: agentId) else {
            throw ValidationError("Agente desconocido.")
        }
        guard let path = params["path"]?.stringValue, let content = params["content"]?.stringValue else {
            throw ValidationError("Faltan los parámetros path y content.")
        }
        let files = try AgentFiles.forAgent(agentId, db: db, paths: paths)
        let write = try files.prepareWrite(path, content: content) // valida antes de molestar al usuario
        let request = FileWriteRequest(agentName: agent.name, path: write.path, content: content,
                                       replaces: write.replaces, previousSize: write.previousSize)
        guard await approve(request) else { throw ValidationError("El usuario no permitió escribir \(write.path).") }
        try Task.checkCancellation()
        try files.commit(write)
        return ["written": .string(write.path), "bytes": .number(Double(content.utf8.count))]
    }
}
