import type { DialConfig, ResolvedValues, SelectConfig, TransitionConfig } from "dialkit";
import { spring } from "motion";

/**
 * One component's DialKit panel, and how its values land on the running component. The CSS goes in
 * a stylesheet inside the component's iframe, so a real component is retuned without editing it.
 */
export type Dials<T extends DialConfig = DialConfig> = { config: T; css: (values: ResolvedValues<T>) => string };

export const dials = <T extends DialConfig>(config: T, css: (values: ResolvedValues<T>) => string): Dials<T> => ({ config, css });

/** What a demo's own code reads when a dial feeds a prop instead of a style. */
export type Tuned<D> = D extends Dials<infer T> ? ResolvedValues<T> : never;

/** A dial's motion as CSS: a cubic-bezier for an easing, and a sampled `linear()` for a spring. */
export function curve(value: TransitionConfig): { ms: number; ease: string } {
  if (value.type === "easing") return { ms: Math.round(value.duration * 1000), ease: `cubic-bezier(${value.ease.join(", ")})` };
  const { type: _type, ...physics } = value;
  const text = spring({ keyframes: [0, 1], ...physics }).toString();
  const split = text.indexOf("ms ");
  return { ms: Number(text.slice(0, split)), ease: text.slice(split + 3) };
}

type Value = unknown;

const isFolder = (entry: object) => !("type" in entry);

/** The panel's values with nothing touched, overlaid with what DialKit saved under each dotted path. */
export function resolveValues(config: DialConfig, saved: Record<string, Value> = {}, prefix = ""): Record<string, Value> {
  const out: Record<string, Value> = {};
  for (const [key, entry] of Object.entries(config)) {
    if (key === "_collapsed") continue;
    const path = prefix + key;
    if (entry && typeof entry === "object" && !Array.isArray(entry) && isFolder(entry)) {
      out[key] = resolveValues(entry as DialConfig, saved, `${path}.`);
      continue;
    }
    const rest = defaultOf(entry);
    if (rest === undefined) continue;
    out[key] = path in saved ? saved[path] : rest;
  }
  return out;
}

function defaultOf(entry: DialConfig[string]): Value {
  if (Array.isArray(entry)) return entry[0];
  if (entry === null || typeof entry !== "object" || !("type" in entry)) return entry;
  switch (entry.type) {
    case "action":
      return undefined;
    case "select": {
      const { default: chosen, options } = entry as SelectConfig;
      const first = options[0];
      return chosen ?? (typeof first === "string" ? first : first?.value);
    }
    case "color":
    case "image":
    case "text":
      return entry.default ?? "";
    default:
      return entry;
  }
}

export const tuneChannel = (id: string) => `tune:${id}`;
export const tuneKey = (id: string) => `dialkit:${id}`;
