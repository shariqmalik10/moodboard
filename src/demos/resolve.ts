import type { DialConfig } from "dialkit";
import { paperDemo } from "../paper/demo";
import type { PaperRecord } from "../paper/derive";
import { DEMOS } from "./registry";
import type { Demo } from "./types";

/** What the app holds for a component from a connected project. The project's own server runs it, so this is only its panel. */
type ProjectRecord = { kind: "project"; id: string; title: string; project: string; root: string; file: string; exportName: string; config: DialConfig };

async function appRecord(id: string): Promise<PaperRecord | ProjectRecord | null> {
  if (DEMOS.some((each) => each.id === id)) return null;
  const response = await fetch(`api/component?id=${encodeURIComponent(id)}`);
  return response.ok ? ((await response.json()) as PaperRecord | ProjectRecord | null) : null;
}

const isProject = (record: PaperRecord | ProjectRecord): record is ProjectRecord => "kind" in record && record.kind === "project";

/** What the app holds for a design imported from Paper. Other components have none. */
export async function paperRecord(id: string): Promise<PaperRecord | null> {
  const record = await appRecord(id);
  return record && !isProject(record) ? record : null;
}

function projectDemo(record: ProjectRecord): Demo {
  return {
    id: record.id,
    project: record.project as Demo["project"],
    title: record.title,
    viewport: { w: 760, h: 600 },
    ground: "#ffffff",
    cursor: "arrow",
    script: [],
    dials: { config: record.config, css: () => "" },
    place: { root: record.root, file: record.file, exportName: record.exportName },
    load: () => Promise.reject(new Error("A project's own server runs its components")),
  };
}

export async function resolveDemo(id: string): Promise<Demo> {
  const demo = DEMOS.find((each) => each.id === id);
  if (demo) return demo;
  const record = await appRecord(id);
  if (!record) throw new Error(`No component called ${id}`);
  return isProject(record) ? projectDemo(record) : paperDemo(record);
}
