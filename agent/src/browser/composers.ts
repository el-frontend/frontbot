import type { Step } from "./steps.js";

export type Network = "instagram" | "linkedin";

export type Composer = {
  network: Network;
  name: string;
  startUrl: string;
  loginPatterns: RegExp[];
  requiresMedia: boolean;
  steps: Step[];
};

const next = ['div[role="button"]:text-is("Next")', 'div[role="button"]:text-is("Siguiente")', 'button:text-is("Next")', 'button:text-is("Siguiente")'];

/**
 * Selectores candidatos por paso (inglés y español). Si una red cambia su interfaz,
 * se arregla aquí. Ningún paso pulsa Compartir/Publicar: eso lo hace el usuario.
 */
export const COMPOSERS: Record<Network, Composer> = {
  instagram: {
    network: "instagram",
    name: "Instagram",
    startUrl: "https://www.instagram.com/",
    loginPatterns: [/\/accounts\/login/, /\/challenge\//],
    requiresMedia: true,
    steps: [
      { kind: "click", label: "Crear", candidates: ['[aria-label="New post"]', '[aria-label="Nueva publicación"]', 'svg[aria-label="New post"]', 'svg[aria-label="Nueva publicación"]', 'a:has-text("Create")', 'a:has-text("Crear")'] },
      { kind: "click", label: "Publicación", optional: true, candidates: ['a:has(span:text-is("Post"))', 'a:has(span:text-is("Publicación"))', '[role="menuitem"]:has-text("Post")', '[role="menuitem"]:has-text("Publicación")'] },
      { kind: "upload", label: "Seleccionar imágenes", candidates: ['input[type="file"][accept*="image"]', 'input[type="file"]'] },
      { kind: "click", label: "Siguiente (recorte)", candidates: next },
      { kind: "click", label: "Siguiente (filtros)", candidates: next },
      { kind: "fill", label: "Pie de foto", candidates: ['[aria-label="Write a caption..."]', '[aria-label="Escribe un pie de foto..."]', 'div[role="textbox"][contenteditable="true"]', 'textarea'] },
    ],
  },
  linkedin: {
    network: "linkedin",
    name: "LinkedIn",
    startUrl: "https://www.linkedin.com/feed/",
    loginPatterns: [/\/login/, /\/checkpoint\//, /\/authwall/, /\/uas\/login/],
    requiresMedia: false,
    steps: [
      { kind: "click", label: "Empezar una publicación", candidates: ['button:has-text("Start a post")', 'button:has-text("Empezar una publicación")', 'button:has-text("Crear publicación")', '.share-box-feed-entry__trigger'] },
      { kind: "click", label: "Añadir multimedia", onlyIfMedia: true, candidates: ['button[aria-label="Add media"]', 'button[aria-label="Añadir contenido multimedia"]', 'button[aria-label="Añadir multimedia"]'] },
      { kind: "upload", label: "Seleccionar imágenes", onlyIfMedia: true, candidates: ['input[type="file"]'] },
      { kind: "click", label: "Siguiente (multimedia)", onlyIfMedia: true, candidates: ['button:has-text("Next")', 'button:has-text("Siguiente")'] },
      { kind: "fill", label: "Texto del post", candidates: ['div.ql-editor[contenteditable="true"]', 'div[role="textbox"][contenteditable="true"]'] },
    ],
  },
};
