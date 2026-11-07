import type { DialConfig } from "dialkit";
import { resolveValues } from "../demos/tune";
import { derive, type PaperRecord } from "./derive";
import { parseJsx, type PaperValue } from "./parse";
import { printJsx } from "./print";

type Values = Record<string, unknown>;

export type Change = { dial: string; from: unknown; to: unknown };

export type Brief = {
  id: string;
  title: string;
  project: string;
  viewport: { w: number; h: number };
  dials: string[];
  changes: Change[];
  css: string;
  jsx?: string;
  source?: PaperRecord["source"];
  place?: { root: string; file: string; exportName: string };
  markdown: string;
};

const isFolder = (value: unknown): value is Values => typeof value === "object" && value !== null && !Array.isArray(value) && !("type" in value);

/** Dial paths and their values, in the dotted form the panel saves them in. */
export function flatten(values: Values, prefix = ""): Record<string, unknown> {
  return Object.fromEntries(
    Object.entries(values).flatMap(([key, value]) => (isFolder(value) ? Object.entries(flatten(value, `${prefix}${key}.`)) : [[`${prefix}${key}`, value]])),
  );
}

/** The same value however its keys are ordered, since saved tunes come back through the app in another order. */
function canonical(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(canonical);
  if (typeof value !== "object" || value === null) return value;
  return Object.fromEntries(Object.entries(value).sort(([a], [b]) => a.localeCompare(b)).map(([key, each]) => [key, canonical(each)]));
}

export function changesBetween(defaults: Values, values: Values): Change[] {
  const before = flatten(defaults);
  return Object.entries(flatten(values))
    .filter(([dial, to]) => JSON.stringify(canonical(before[dial])) !== JSON.stringify(canonical(to)))
    .map(([dial, to]) => ({ dial, from: before[dial], to }));
}

/** The design as Paper drew it with the tune written into it, so nobody has to apply corrections by hand. */
export function tunedJsx(record: PaperRecord, values: Values) {
  const derived = derive(parseJsx(record.jsx), record.tokens);
  const vars = derived.vars(values);
  const words = Object.values((values.Text ?? {}) as Record<string, string>);
  const texts = new Map(derived.texts.map((text, at) => [text, words[at] ?? text]));
  const value = (each: PaperValue) => (typeof each === "string" ? each.replace(/var\((--paper-[\w-]+)\)/g, (whole, name: string) => vars[name] ?? whole) : each);
  return printJsx(derived.tree, { value, text: (text) => texts.get(text) ?? text });
}

const show = (value: unknown) => (typeof value === "object" ? JSON.stringify(value) : String(value));

function writeMarkdown(brief: Omit<Brief, "markdown">, note?: string) {
  const lines = [`# ${brief.title}`, ""];
  if (brief.place) {
    lines.push(`A real component in the ${brief.project} project: \`${brief.place.exportName}\` in \`${brief.place.file}\`. It runs live on the person's Moodboard wall from this file, so a saved edit shows there at once. Dials on the wall edit this file directly, so their values are already in the source. Any "Sample props" below are made-up data for the wall, not part of the component.`);
  } else if (brief.source) {
    lines.push(`Designed in Paper${brief.source.fileName ? `, in "${brief.source.fileName}"` : ""}, at ${brief.viewport.w} × ${brief.viewport.h}. The person then tuned it by eye on their Moodboard wall.`);
  } else {
    lines.push(`A real component from the ${brief.project} project, running isolated on the person's Moodboard wall. Find it in the repository by name.`);
  }
  lines.push("", "## What was tuned", "");
  if (brief.changes.length === 0) lines.push("Nothing. These are the values as designed.");
  for (const change of brief.changes) lines.push(`- ${change.dial}: ${show(change.from)} → ${show(change.to)}`);
  if (note?.trim()) lines.push("", "## What the person wants", "", note.trim());
  if (brief.jsx) lines.push("", "## The design, with the tune already in it", "", "```jsx", brief.jsx, "```");
  if (brief.place) return lines.join("\n");
  lines.push("", "## Tokens and motion", "", "```css", brief.css.trim(), "```");
  lines.push(
    "",
    "## Building it",
    "",
    "- Treat the values above as final. The person chose them by looking at the component.",
    "- Use the repository's own components, tokens and conventions. Inline styles here describe the look, and aren't a request for inline styles.",
    "- Give pressable things real semantics, keyboard access and focus states, which a static design can't show.",
    "- `.paper-root` and `.paper-press` are the wall's own class names. Carry their motion over without the names.",
  );
  return lines.join("\n");
}

/** What the wall shows about a tune: each moved dial, and one string that is the same whenever the tune is. */
export function tuneSummary(config: DialConfig, saved: Values) {
  const changes = changesBetween(resolveValues(config, {}) as Values, resolveValues(config, saved) as Values).sort((a, b) => a.dial.localeCompare(b.dial));
  return { changes, key: JSON.stringify(canonical(changes)) };
}

export function writeBrief(demo: { id: string; title: string; project: string; viewport: { w: number; h: number }; dials: { config: DialConfig; css: (values: Values) => string }; place?: Brief["place"] }, saved: Values, record: PaperRecord | null, note?: string): Brief {
  const defaults = resolveValues(demo.dials.config, {}) as Values;
  const values = resolveValues(demo.dials.config, saved) as Values;
  const brief: Omit<Brief, "markdown"> = {
    id: demo.id,
    title: demo.title,
    project: demo.project,
    viewport: demo.viewport,
    dials: Object.keys(flatten(defaults)),
    changes: changesBetween(defaults, values),
    css: demo.dials.css(values),
    jsx: record ? tunedJsx(record, values) : undefined,
    source: record?.source,
    place: demo.place,
  };
  return { ...brief, markdown: writeMarkdown(brief, note) };
}
