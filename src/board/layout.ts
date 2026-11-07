/** The wall's grain: every column is this wide, and the wall repeats every N of them, forever. */
export const CARD_W = 320;
export const GAP = 28;
const PITCH = CARD_W + GAP;

/** Pushes each column's start down a different amount, so the tops never line up into a grid. */
const STAGGER = [0, 96, 28, 148, 56, 120, 12, 84];
/** Each repeat of the whole wall slides this far, so a repeat never reads as the same picture. */
const WRAP_SHIFT = 317;

const mod = (value: number, by: number) => ((value % by) + by) % by;

type LaidCard = { id: string; y: number; h: number };
type Column = { cards: LaidCard[]; height: number; stagger: number };
export type Layout = { columns: Column[] };

/** One card somewhere on the endless wall. `key` survives reflows, so its iframe stays alive. */
export type Instance = { key: string; id: string; x: number; y: number; w: number; h: number };
export type Rect = { x0: number; y0: number; x1: number; y1: number };

export function buildLayout(columns: string[][], heightOf: (id: string) => number): Layout {
  return {
    columns: columns
      .filter((list) => list.length > 0)
      .map((list, at) => {
        let y = 0;
        const cards = list.map((id) => {
          const h = heightOf(id);
          const card = { id, y, h };
          y += h + GAP;
          return card;
        });
        return { cards, height: y, stagger: STAGGER[at % STAGGER.length] };
      }),
  };
}

function columnAt(layout: Layout, cx: number) {
  const count = layout.columns.length;
  const column = layout.columns[mod(cx, count)];
  const wrap = Math.floor(cx / count);
  return { column, origin: column.stagger + wrap * WRAP_SHIFT, repeat: wrap };
}

export function cardsIn(layout: Layout, rect: Rect): Instance[] {
  if (layout.columns.length === 0) return [];
  const found: Instance[] = [];
  for (let cx = Math.floor(rect.x0 / PITCH); cx * PITCH < rect.x1; cx++) {
    const x = cx * PITCH;
    if (x + CARD_W < rect.x0) continue;
    const { column, origin } = columnAt(layout, cx);
    for (let k = Math.floor((rect.y0 - origin) / column.height) - 1; origin + k * column.height < rect.y1; k++) {
      for (const card of column.cards) {
        const y = origin + k * column.height + card.y;
        if (y < rect.y1 && y + card.h > rect.y0) found.push({ key: `${card.id}|${cx}|${k}`, id: card.id, x, y, w: CARD_W, h: card.h });
      }
    }
  }
  return found;
}

/** Where a card dropped at this point of the wall belongs: which column, and before which card. */
export function slotAt(layout: Layout, worldX: number, worldY: number) {
  const cx = Math.floor((worldX + GAP / 2) / PITCH);
  const { column, origin } = columnAt(layout, cx);
  const count = layout.columns.length;
  const inRepeat = mod(worldY - origin, column.height);
  const index = column.cards.findIndex((card) => inRepeat < card.y + card.h / 2);
  return { column: mod(cx, count), index: index < 0 ? column.cards.length : index };
}
