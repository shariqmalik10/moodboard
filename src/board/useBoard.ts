import { useEffect, useMemo, useState } from "react";
import boardFile from "../board.json";
import { DEMOS } from "../demos/registry";
import type { Demo } from "../demos/types";
import type { BoardFile, Placement } from "./board-model";
import { itemsOf } from "./items";

/** Only the local server can write. A published wall is read-only and shows what was built in. */
export const CAN_EDIT = import.meta.env.DEV;

let current = boardFile as BoardFile;
let demos = DEMOS;
const listeners = new Set<() => void>();
const asked = new Set<string>();
const changed = () => listeners.forEach((listener) => listener());

// The board file on disk is the truth. Anything that writes it, from any tab or tool, reaches here.
if (import.meta.hot) {
  import.meta.hot.accept("../board.json", (next) => {
    if (!next) return;
    current = next.default as BoardFile;
    changed();
  });
  import.meta.hot.accept("../demos/registry", (next) => {
    if (!next) return;
    demos = next.DEMOS as Demo[];
    changed();
  });
}

const post = (path: string, body: unknown) => fetch(`/__board/${path}`, { method: "POST", body: JSON.stringify(body) });

export const placeOnWall = (id: string, at?: Placement) => post("place", { id, ...at });
export const removeFromWall = (id: string) => post("remove", { id });

async function shapeOf(file: File): Promise<{ w: number; h: number; bare: boolean }> {
  if (file.type.startsWith("video/")) {
    const video = document.createElement("video");
    video.src = URL.createObjectURL(file);
    await new Promise((resolve, reject) => {
      video.onloadedmetadata = resolve;
      video.onerror = reject;
    });
    URL.revokeObjectURL(video.src);
    return { w: video.videoWidth, h: video.videoHeight, bare: false };
  }
  const bitmap = await createImageBitmap(file);
  const canvas = document.createElement("canvas");
  canvas.width = 8;
  canvas.height = 8;
  const context = canvas.getContext("2d", { willReadFrequently: true });
  context?.drawImage(bitmap, 0, 0, 8, 8);
  const corners = [[0, 0], [7, 0], [0, 7], [7, 7]].map(([x, y]) => context?.getImageData(x, y, 1, 1).data[3] ?? 255);
  const shape = { w: bitmap.width, h: bitmap.height, bare: corners.every((alpha) => alpha < 12) };
  bitmap.close();
  return shape;
}

/** Sends a file to the local server; the wall hears back through the board file like everything else. */
export async function addMaterial(file: File, at?: Placement) {
  if (!/^(image|video)\//.test(file.type)) throw new Error(`Only images and video go on the wall, and ${file.name} is neither.`);
  const shape = await shapeOf(file);
  const query = new URLSearchParams({ name: file.name, w: String(shape.w), h: String(shape.h), bare: shape.bare ? "1" : "", column: String(at?.column ?? -1), index: String(at?.index ?? 0) });
  const response = await fetch(`/__board/material?${query}`, { method: "POST", body: file });
  if (!response.ok) throw new Error(((await response.json()) as { error: string }).error);
}

export function useBoard() {
  const [, redraw] = useState(0);
  useEffect(() => {
    const listener = () => redraw((count) => count + 1);
    listeners.add(listener);
    return () => void listeners.delete(listener);
  }, []);
  const board = current;
  const shown = demos;
  const items = useMemo(() => itemsOf(board, shown), [board, shown]);
  const onWall = useMemo(() => new Set(board.columns.flat()), [board]);
  const offWall = useMemo(() => shown.filter((demo) => !onWall.has(demo.id)), [shown, onWall]);

  // A component that has never been on the wall arrives by itself. One taken off stays off.
  useEffect(() => {
    if (!CAN_EDIT) return;
    const hidden = new Set(board.hidden ?? []);
    for (const demo of offWall) {
      if (hidden.has(demo.id) || asked.has(demo.id)) continue;
      asked.add(demo.id);
      void placeOnWall(demo.id);
    }
  }, [board, offWall]);

  return { columns: board.columns, items, offWall };
}
