import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { DialStore, type DialConfig } from "dialkit";
import { describe, expect, it } from "vitest";
import "../board/dial-store";
import { DEMOS } from "./registry";
import { curve, resolveValues } from "./tune";

type Leaf = { path: string; entry: unknown };

const leaves = (config: DialConfig, prefix = ""): Leaf[] =>
  Object.entries(config).flatMap(([key, entry]): Leaf[] => {
    if (key === "_collapsed") return [];
    const isFolder = entry && typeof entry === "object" && !Array.isArray(entry) && !("type" in entry);
    return isFolder ? leaves(entry as DialConfig, `${prefix}${key}.`) : [{ path: prefix + key, entry }];
  });

const moved = (entry: unknown): unknown => {
  if (Array.isArray(entry)) return entry[0] === entry[2] ? entry[1] : entry[2];
  if (typeof entry === "boolean") return !entry;
  if (typeof entry === "string") return entry.startsWith("#") ? "#123456" : "changed";
  const typed = entry as { type: string; duration?: number; options?: unknown[] };
  if (typed.type === "select") return typed.options?.at(-1);
  if (typed.type === "easing") return { ...typed, duration: 1.3 };
  return { type: "spring", visualDuration: 1.3, bounce: 0.4 };
};

const sourceOf = (dir: string) =>
  readdirSync(dir)
    .filter((file) => file.endsWith(".tsx"))
    .map((file) => readFileSync(join(dir, file), "utf8"))
    .join("\n");

const STAGE = readFileSync("src/stage/main.tsx", "utf8") + sourceOf("src/stage/shims");
const sourceFor = (project: string) => sourceOf(join("src/demos", project)) + STAGE;

describe("resolveValues", () => {
  const config = {
    Motion: { rise: [8, 0, 32, 1], open: { type: "easing", duration: 0.2, ease: [0.2, 0, 0, 1] } },
    Theme: { _collapsed: true, night: false },
    Content: { head: "Monstera", mode: { type: "select", options: ["one", "two"] } },
    replay: { type: "action", label: "Replay" },
  } as unknown as DialConfig;

  it("gives every default when nothing was saved, without the panel's own keys", () => {
    expect(resolveValues(config)).toEqual({
      Motion: { rise: 8, open: { type: "easing", duration: 0.2, ease: [0.2, 0, 0, 1] } },
      Theme: { night: false },
      Content: { head: "Monstera", mode: "one" },
    });
  });

  it("puts a saved value back under its dotted path and leaves the others alone", () => {
    const values = resolveValues(config, { "Motion.rise": 20, "Theme.night": true }) as { Motion: { rise: number }; Theme: { night: boolean }; Content: { head: string } };
    expect(values.Motion.rise).toBe(20);
    expect(values.Theme.night).toBe(true);
    expect(values.Content.head).toBe("Monstera");
  });
});

describe("a motion dial reopened", () => {
  const spring = { type: "spring", stiffness: 300, damping: 20, mass: 1 };
  const easing = { type: "easing", duration: 0.2, ease: [0.2, 0, 0, 1] };

  it.each([
    ["a spring on an easing dial", easing, spring],
    ["an easing on a spring dial", spring, easing],
  ])("keeps %s", (name, rest, chosen) => {
    const config = { open: rest } as unknown as DialConfig;
    DialStore.registerPanel(name, name, config);
    DialStore.updateValue(name, "open", chosen as never);
    DialStore.updatePanel(name, name, config);
    expect(DialStore.getValues(name).open).toEqual(chosen);
  });
});

describe("curve", () => {
  it("turns an easing into a duration and a cubic-bezier", () => {
    expect(curve({ type: "easing", duration: 0.12, ease: [0.2, 0, 0, 1] })).toEqual({ ms: 120, ease: "cubic-bezier(0.2, 0, 0, 1)" });
  });

  it("turns a spring into a duration and a linear() that CSS can run", () => {
    const { ms, ease } = curve({ type: "spring", visualDuration: 0.4, bounce: 0.3 });
    expect(ms).toBeGreaterThan(0);
    expect(ease).toMatch(/^linear\(0, .*, 1\)$/);
  });

  it("does the same for a spring given by its physics", () => {
    const { ms, ease } = curve({ type: "spring", stiffness: 300, damping: 20, mass: 1 });
    expect(ms).toBeGreaterThan(0);
    expect(ease).toMatch(/^linear\(/);
  });
});

describe.each(DEMOS.map((demo) => [demo.id, demo] as const))("%s", (_id, demo) => {
  const { config, css } = demo.dials;
  const defaults = () => structuredClone(resolveValues(config));
  const leafs = leaves(config).filter(({ entry }) => (entry as { type?: string })?.type !== "action");

  it("writes valid-looking CSS from its defaults", () => {
    const sheet = css(defaults() as never);
    expect(sheet).not.toMatch(/undefined|NaN|\[object/);
    expect(sheet.split("{").length).toBe(sheet.split("}").length);
  });

  it("has no dial that does nothing", () => {
    const base = css(defaults() as never);
    const inert = leafs.filter(({ path, entry }) => {
      const values = defaults();
      const parts = path.split(".");
      let at = values as Record<string, unknown>;
      for (const part of parts.slice(0, -1)) at = at[part] as Record<string, unknown>;
      at[parts.at(-1)!] = moved(entry);
      if (css(values as never) !== base) return false;
      return !new RegExp(`\\b${parts.at(-1)}\\b`).test(sourceFor(demo.project));
    });
    expect(inert.map((leaf) => leaf.path)).toEqual([]);
  });

  it("survives its motion dials becoming springs", () => {
    const motion = leafs.filter(({ entry }) => (entry as { type?: string })?.type === "easing");
    if (!motion.length) return;
    const values = defaults();
    for (const { path } of motion) {
      const parts = path.split(".");
      let at = values as Record<string, unknown>;
      for (const part of parts.slice(0, -1)) at = at[part] as Record<string, unknown>;
      at[parts.at(-1)!] = { type: "spring", visualDuration: 0.4, bounce: 0.3 };
    }
    expect(css(values as never)).not.toMatch(/undefined|NaN|\[object/);
  });
});
