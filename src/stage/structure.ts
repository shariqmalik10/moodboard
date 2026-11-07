export type Rgba = [number, number, number, number];

/** One thing the component paints, in the crop's own pixels. The app assembles a tile from these as you scroll to it. */
export type Piece = {
  kind: "box" | "text" | "media";
  x: number;
  y: number;
  w: number;
  h: number;
  radius: number;
  fill?: Rgba;
  stroke?: Rgba;
  strokeWidth?: number;
};

export type Crop = { x: number; y: number; w: number; h: number };

const MEDIA = new Set(["IMG", "SVG", "CANVAS", "VIDEO", "PICTURE"]);
const MIN_SIDE = 2;

const painter = document.createElement("canvas").getContext("2d", { willReadFrequently: true });
const colours = new Map<string, Rgba>();

/** Computed colours can be written in any colour space, so the browser paints one pixel and reads it back. */
function rgba(css: string): Rgba {
  const known = colours.get(css);
  if (known) return known;
  let out: Rgba = [0, 0, 0, 0];
  if (painter) {
    painter.clearRect(0, 0, 1, 1);
    painter.fillStyle = css;
    painter.fillRect(0, 0, 1, 1);
    const [r, g, b, a] = painter.getImageData(0, 0, 1, 1).data;
    out = [r / 255, g / 255, b / 255, a / 255];
  }
  colours.set(css, out);
  return out;
}

function inCrop(rect: { left: number; top: number; right: number; bottom: number }, crop: Crop) {
  const x = Math.max(rect.left, crop.x);
  const y = Math.max(rect.top, crop.y);
  const w = Math.min(rect.right, crop.x + crop.w) - x;
  const h = Math.min(rect.bottom, crop.y + crop.h) - y;
  if (w < MIN_SIDE || h < MIN_SIDE) return null;
  return { x: x - crop.x, y: y - crop.y, w, h };
}

function textLines(element: Element, crop: Crop, colour: Rgba, out: Piece[]) {
  for (const node of element.childNodes) {
    if (node.nodeType !== Node.TEXT_NODE || !node.textContent?.trim()) continue;
    const range = document.createRange();
    range.selectNodeContents(node);
    for (const line of range.getClientRects()) {
      const box = inCrop(line, crop);
      if (box) out.push({ kind: "text", ...box, radius: Math.min(3, box.h / 2), fill: colour });
    }
  }
}

function walk(element: Element, crop: Crop, opacity: number, out: Piece[]) {
  const style = getComputedStyle(element);
  if (style.display === "none" || style.visibility === "hidden") return;
  const seen = opacity * Number(style.opacity);
  if (seen < 0.05) return;
  const box = inCrop(element.getBoundingClientRect(), crop);

  if (box) {
    const fill = rgba(style.backgroundColor);
    const strokeWidth = Number.parseFloat(style.borderTopWidth) || 0;
    const stroke = strokeWidth > 0 ? rgba(style.borderTopColor) : undefined;
    const painted = fill[3] > 0.02 || style.backgroundImage !== "none" || (stroke !== undefined && stroke[3] > 0.02);
    const radius = Number.parseFloat(style.borderTopLeftRadius) || 0;
    if (MEDIA.has(element.tagName.toUpperCase())) {
      out.push({ kind: "media", ...box, radius });
      return;
    }
    if (painted) out.push({ kind: "box", ...box, radius, fill, stroke, strokeWidth });
  }
  textLines(element, crop, rgba(style.color), out);
  for (const child of element.children) walk(child, crop, seen, out);
}

/** The biggest pieces carry the shape, so a crowded component keeps those and drops the smallest. */
export function readStructure(crop: Crop, limit = 56): Piece[] {
  const root = document.getElementById("stage");
  if (!root) return [];
  const found: Piece[] = [];
  walk(root, crop, 1, found);
  if (found.length <= limit) return found;
  const kept = new Set([...found].sort((a, b) => b.w * b.h - a.w * a.h).slice(0, limit));
  return found.filter((piece) => kept.has(piece));
}
