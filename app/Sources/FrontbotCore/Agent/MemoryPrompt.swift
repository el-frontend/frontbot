import Foundation

/// Qué parte de la memoria entra en el prompt de un run.
public enum MemoryPrompt {
    public static let budget = 6_000

    /// Las notas más recientes que caben en `budget` caracteres (recibe las más nuevas primero).
    public static func trimmed(_ memories: [AgentMemory], budget: Int = budget) -> [AgentMemory] {
        var used = 0
        var kept: [AgentMemory] = []
        for m in memories {
            used += m.text.count
            if used > budget { break }
            kept.append(m)
        }
        return kept
    }

    public static func json(_ memories: [AgentMemory]) -> JSONValue {
        .array(memories.map { ["text": .string($0.text), "date": .string(String(ToolHandler.isoString($0.createdAt).prefix(10)))] })
    }
}
