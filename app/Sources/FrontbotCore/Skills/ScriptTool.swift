import Foundation

/// Lo que el usuario ve antes de permitir un script.
public struct ScriptRequest: Equatable, Sendable {
    public let agentName: String
    public let skillName: String
    public let command: String
}

/// `tool.skills_run_script`: valida, pide aprobación al usuario y ejecuta en la sandbox.
public struct ScriptTool: Sendable {
    let library: SkillLibrary
    let sandbox: ScriptSandbox

    public init(library: SkillLibrary, sandbox: ScriptSandbox = ScriptSandbox()) {
        self.library = library
        self.sandbox = sandbox
    }

    public func run(params: JSONValue, approve: @Sendable (ScriptRequest) async -> Bool) async throws -> JSONValue {
        guard let agentId = params["agent_id"]?.stringValue, let agent = try library.db.agent(id: agentId) else {
            throw ValidationError("Agente desconocido.")
        }
        guard let skillName = params["skill"]?.stringValue, let script = params["script"]?.stringValue else {
            throw ValidationError("Faltan los parámetros skill y script.")
        }
        let args = (params["args"]?.arrayValue ?? []).compactMap(\.stringValue)
        guard let skill = try library.skills(assignedTo: agentId, activeOnly: true).first(where: { $0.name == skillName }) else {
            throw ValidationError("No tienes un skill activo llamado \(skillName).")
        }
        let dir = library.directory(for: skill)
        _ = try ScriptSandbox.resolve(script: script, in: dir, nodePath: sandbox.nodePath) // valida antes de molestar al usuario
        let request = ScriptRequest(agentName: agent.name, skillName: skill.name, command: ([script] + args).joined(separator: " "))
        guard await approve(request) else { throw ValidationError("El usuario denegó la ejecución del script.") }
        try Task.checkCancellation()
        let sandbox = self.sandbox
        let execution = Task.detached {
            try Task.checkCancellation()
            let watch = ScriptSandbox.Watch(interval: 0.1) { Task.isCancelled ? "Ejecución cancelada." : nil }
            return try sandbox.run(script: script, args: args, in: dir, watch: watch)
        }
        let result = try await withTaskCancellationHandler {
            try await execution.value
        } onCancel: {
            execution.cancel()
        }
        try Task.checkCancellation()
        return ["exit_code": .number(Double(result.exitCode)), "stdout": .string(result.stdout),
                "stderr": .string(result.stderr), "timed_out": .bool(result.timedOut)]
    }
}
