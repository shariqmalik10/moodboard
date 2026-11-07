import type { Demo } from "./types";

/** Every hand-written component. A folder here whose `index.ts` exports an array of demos joins the wall. */
const folders = import.meta.glob<Record<string, unknown>>("./*/index.ts", { eager: true });

export const DEMOS: Demo[] = Object.values(folders).flatMap((module) => Object.values(module).filter(Array.isArray).flat() as Demo[]);
