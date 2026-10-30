import Foundation
import PDFKit

/// Material para crear la guía de marca: texto de un PDF y los prompts que guían al agente.
public enum GuideSources {
    public static let maxPDFCharacters = 60_000

    static let sections = "## Tono de voz, ## Público, ## Pilares de contenido, ## Palabras sí / palabras no, ## Ejemplos, ## Identidad visual"

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

    public static func linksPrompt(brandName: String, links: [String], hasGuide: Bool) -> String {
        let list = links.map { "- \($0)" }.joined(separator: "\n")
        let save = hasGuide
            ? "Esta marca ya tiene guía: antes de guardar, muéstrame un resumen de lo que cambia y pregúntame si la reemplazo. Guárdala con brands_write_guide solo si te digo que sí."
            : "Guárdala con brands_write_guide."
        return """
        Crea la guía de marca de \(brandName) a partir de estos links:
        \(list)

        1. Lee cada link. Usa WebFetch para lo público; si es un perfil de red social o pide sesión y tienes el navegador, \
        úsalo. Si un link no se puede leer, dilo y sigue con los demás.
        2. Escribe la guía en markdown con estas secciones: \(sections). En "Identidad visual" anota los colores en hex, \
        las tipografías si se ven y el estilo de las fotos. En "Ejemplos" cita textos reales publicados, tal cual. Lo que \
        no salga de los links déjalo como "(por definir)". No inventes nada.
        3. \(save)
        4. Importa con brands_import_image el logo (kind: logo, como máximo 1) y hasta 8 fotos representativas \
        (kind: image). Evita iconos, banners, capturas de interfaz y fotos de stock.
        5. Termina diciéndome qué sacaste de cada link, qué secciones quedaron "(por definir)" y qué imágenes importaste.
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
