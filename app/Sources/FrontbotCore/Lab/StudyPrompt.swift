import Foundation

/// Cuaderno que se entrega al sidecar al arrancar una sesión de estudio.
public enum StudyPrompt {
    static let fullEntries = 30
    static let oldEntryLimit = 300
    static let maxModelNotes = 20

    /// Últimas 30 entradas completas; de las anteriores, solo conclusiones y resultados recortados a 300 caracteres.
    /// `model_notes`: las últimas 20 notas sobre el modelo del agente, de todos sus temas.
    public static func payload(topic: LabTopic, entries: [LabEntry], modelNotes: [LabEntry], datasets: [DatasetMeta], files: [String]) -> JSONValue {
        let recent = entries.suffix(fullEntries)
        let older = entries.dropLast(recent.count).filter { $0.kind == .conclusion || $0.kind == .result }
        func date(_ d: Date) -> JSONValue { .string(ToolHandler.isoString(d)) }
        return [
            "conclusion": topic.conclusion.map(JSONValue.string) ?? .null,
            "earlier": .array(older.map { ["kind": .string($0.kind.rawValue), "text": .string(String($0.text.prefix(oldEntryLimit))), "date": date($0.createdAt)] }),
            "entries": .array(recent.map { e in
                ["kind": .string(e.kind.rawValue), "text": .string(e.text), "evidence": e.evidence.map { .string($0.rawValue) } ?? .null,
                 "sources": .array(e.sources.map(JSONValue.string)), "date": date(e.createdAt)]
            }),
            "model_notes": .array(modelNotes.suffix(maxModelNotes).map { ["text": .string($0.text), "date": date($0.createdAt)] }),
            "datasets": .array(datasets.map { ["name": .string($0.name), "description": .string($0.description), "files": .array($0.files.map(JSONValue.string)), "bytes": .number(Double($0.bytes))] }),
            "files": .array(files.map(JSONValue.string)),
        ]
    }
}
