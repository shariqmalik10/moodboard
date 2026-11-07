import { DEMOS } from "../demos/registry";
import type { Demo, Project } from "../demos/types";
import type { BoardFile, Material } from "./board-model";
import { CARD_W } from "./layout";

/** What stands on the wall: a live component in an iframe, or a picture or film someone added. */
export type Item = { id: string; title: string; project: Project | "material"; ground: string; dark: boolean; aspect: number } & ({ kind: "demo"; demo: Demo } | { kind: "material"; material: Material });

export const cropOf = (demo: Demo) => demo.crop ?? { x: 0, y: 0, ...demo.viewport };

const clampAspect = (aspect: number) => Math.min(2.2, Math.max(0.45, aspect));

export function itemsOf(board: BoardFile, demos: Demo[] = DEMOS) {
  const items = new Map<string, Item>();
  for (const demo of demos) {
    const crop = cropOf(demo);
    items.set(demo.id, { id: demo.id, title: demo.title, project: demo.project, ground: demo.ground, dark: Boolean(demo.dark), aspect: crop.h / crop.w, kind: "demo", demo });
  }
  for (const [id, material] of Object.entries(board.materials)) {
    items.set(id, { id, title: material.title, project: "material", ground: "#e9ebe6", dark: false, aspect: clampAspect(material.h / material.w), kind: "material", material });
  }
  return items;
}

export const heightOf = (item: Item | undefined) => Math.round(CARD_W * (item?.aspect ?? 1));
