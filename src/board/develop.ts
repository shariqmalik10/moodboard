const CELL = 8;
const REVEAL_MS = 640;
const BAYER = [
  [0, 32, 8, 40, 2, 34, 10, 42],
  [48, 16, 56, 24, 50, 18, 58, 26],
  [12, 44, 4, 36, 14, 46, 6, 38],
  [60, 28, 52, 20, 62, 30, 54, 22],
  [3, 35, 11, 43, 1, 33, 9, 41],
  [51, 19, 59, 27, 49, 17, 57, 25],
  [15, 47, 7, 39, 13, 45, 5, 37],
  [63, 31, 55, 23, 61, 29, 53, 21],
];

function parseColour(hex: string) {
  const value = Number.parseInt(hex.slice(1), 16);
  return [(value >> 16) & 255, (value >> 8) & 255, value & 255];
}

/**
 * A card coming into being: a printed plate of dither while its content loads, then the plate
 * dissolves in Bayer order from the top down. The wait is real, since it lasts until the iframe or
 * image says it is ready, so the wall fills in at the speed things actually arrive.
 */
export function developOn(canvas: HTMLCanvasElement, { ground, dark }: { ground: string; dark: boolean }) {
  const columns = Math.ceil(canvas.clientWidth / CELL) || 1;
  const rows = Math.ceil(canvas.clientHeight / CELL) || 1;
  canvas.width = columns;
  canvas.height = rows;
  const context = canvas.getContext("2d");
  if (!context) return { reveal: (done: () => void) => done(), cancel: () => {} };

  const image = context.createImageData(columns, rows);
  const [r, g, b] = parseColour(ground);
  const ink = dark ? 255 : 0;
  const start = performance.now();
  let revealAt = 0;
  let frame = 0;
  let finished: (() => void) | null = null;

  const paint = (now: number) => {
    const elapsed = now - start;
    const progress = revealAt ? (now - revealAt) / REVEAL_MS : 0;
    const eased = progress * progress * (3 - 2 * Math.min(1, progress));
    const data = image.data;
    for (let y = 0; y < rows; y++) {
      for (let x = 0; x < columns; x++) {
        const at = (y * columns + x) * 4;
        const dither = BAYER[y % 8][x % 8] / 64;
        const gone = revealAt > 0 && eased * 1.5 > dither * 0.55 + (y / rows) * 0.95;
        const wave = 0.5 + 0.5 * Math.sin(x * 0.28 + y * 0.2 - elapsed * 0.0035);
        const marked = dither < 0.06 + wave * 0.16;
        data[at] = marked ? r * 0.9 + ink * 0.1 : r;
        data[at + 1] = marked ? g * 0.9 + ink * 0.1 : g;
        data[at + 2] = marked ? b * 0.9 + ink * 0.1 : b;
        data[at + 3] = gone ? 0 : 255;
      }
    }
    context.putImageData(image, 0, 0);
    if (revealAt && progress >= 1.05) finished?.();
    else frame = requestAnimationFrame(paint);
  };
  frame = requestAnimationFrame(paint);

  return {
    reveal(done: () => void) {
      revealAt = performance.now();
      finished = done;
    },
    cancel() {
      cancelAnimationFrame(frame);
    },
  };
}
