import Foundation
import PDFKit

/// Material para crear la guía de marca: texto de un PDF y los prompts que guían al agente.
public enum GuideSources {
    public static let maxPDFCharacters = 60_000

    static let sections = "## Tono de voz, ## Público, ## Pilares de contenido, ## Palabras sí / palabras no, ## Ejemplos"

    public static func text(fromPDF url: URL) throws -> String {
        guard let doc = PDFDocument(url: url) else { throw ValidationError(String(localized: "No se pudo abrir el PDF.")) }
        let text = (doc.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ValidationError(String(localized: "Este PDF no tiene texto seleccionable.")) }
        return text
    }

    public static func interviewPrompt(brandName: String) -> String {
        """
        Entrevístame para crear la guía de marca de \(brandName). Hazme una pregunta a la vez y espera mi respuesta \
        antes de la siguiente; cubre tono, público, pilares de contenido, palabras que sí y que no usamos, y ejemplos \
        de publicaciones que nos gustan. Cuando tengas suficiente (máximo 8 preguntas), escribe la guía en markdown con \
        estas secciones: \(sections). Guárdala con brands_write_guide y muéstrame un resumen.
        """
    }

    public static func pdfPrompt(brandName: String, pdfText: String) -> String {
        let clipped = pdfText.count > maxPDFCharacters
            ? String(pdfText.prefix(maxPDFCharacters)) + "\n[texto recortado]"
            : pdfText
        return """
        Este es el texto de la guía de marca de \(brandName), extraído de un PDF. Conviértelo en una guía en markdown con \
        estas secciones: \(sections). No inventes datos que no estén en el texto; si falta una sección, déjala con \
        "(por definir)". Guárdala con brands_write_guide y dime qué secciones quedaron por definir.

        --- TEXTO DEL PDF ---
        \(clipped)
        """
    }
}
