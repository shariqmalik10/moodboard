import { describe, expect, it } from "vitest";
import { insertItem, removeItem, type BoardFile } from "./board-model";
import { buildLayout, cardsIn, slotAt, CARD_W } from "./layout";

const layout = buildLayout([["a", "b"], ["c"], ["d", "e", "f"]], () => 200);

describe("the endless wall", () => {
  it("has cards wherever you look, however far you travel", () => {
    for (const [x, y] of [[0, 0], [-90_000, 40_000], [123_456, -987_654]]) {
      const cards = cardsIn(layout, { x0: x, y0: y, x1: x + 1400, y1: y + 900 });
      expect(cards.length).toBeGreaterThan(4);
    }
  });

  it("only returns cards that touch the view", () => {
    const view = { x0: 500, y0: 300, x1: 1500, y1: 1000 };
    for (const card of cardsIn(layout, view)) {
      expect(card.x + card.w).toBeGreaterThan(view.x0);
      expect(card.x).toBeLessThan(view.x1);
      expect(card.y + card.h).toBeGreaterThan(view.y0);
      expect(card.y).toBeLessThan(view.y1);
    }
  });

  it("never lays two cards over each other", () => {
    const cards = cardsIn(layout, { x0: -1500, y0: -1500, x1: 1500, y1: 1500 });
    for (const a of cards) {
      for (const b of cards) {
        if (a.key === b.key || a.x !== b.x) continue;
        expect(a.y + a.h <= b.y || b.y + b.h <= a.y).toBe(true);
      }
    }
    expect(new Set(cards.map((card) => card.key)).size).toBe(cards.length);
  });

  it("keeps a card's key when its column reflows, so its iframe survives", () => {
    const view = { x0: 0, y0: 0, x1: CARD_W, y1: 2000 };
    const before = cardsIn(buildLayout([["a", "b"]], () => 200), view).find((card) => card.id === "b");
    const after = cardsIn(buildLayout([["new", "a", "b"]], () => 200), view).find((card) => card.key === before?.key);
    expect(after?.id).toBe("b");
    expect(after?.y).not.toBe(before?.y);
  });

  it("drops in the column under the pointer, before the card whose middle is below it", () => {
    const flat = buildLayout([["a", "b"], ["c", "d"]], () => 200);
    expect(slotAt(flat, 10, 20).column).toBe(0);
    expect(slotAt(flat, 10, 20).index).toBe(0);
    expect(slotAt(flat, 10, 150).index).toBe(1);
    expect(slotAt(flat, CARD_W + 40, 500).column).toBe(1);
  });
});

describe("the stored board", () => {
  const board: BoardFile = { columns: [["a"], ["b", "c"], []], materials: {} };

  it("adding touches only the chosen column", () => {
    const next = insertItem(board, "x", undefined, { column: 1, index: 1 });
    expect(next.columns).toEqual([["a"], ["b", "x", "c"], []]);
  });

  it("with no column named, adds to the shortest", () => {
    expect(insertItem(board, "x", undefined, { column: -1, index: 0 }).columns[2]).toEqual(["x"]);
  });

  it("adding something already there changes nothing", () => {
    expect(insertItem(board, "a", undefined, { column: 1, index: 0 })).toBe(board);
  });

  it("removing a material drops its row, and a removed component stays off the wall", () => {
    const withMaterial = insertItem(board, "m", { kind: "image", src: "m.png", title: "m", w: 1, h: 1 }, { column: 0, index: 0 });
    const gone = removeItem(withMaterial, "m");
    expect(gone.columns.flat()).not.toContain("m");
    expect(gone.materials.m).toBeUndefined();
    expect(gone.hidden ?? []).not.toContain("m");
    expect(removeItem(board, "a").hidden).toContain("a");
    expect(insertItem(removeItem(board, "a"), "a", undefined, { column: 0, index: 0 }).hidden).not.toContain("a");
  });
});
