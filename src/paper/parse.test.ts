import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { resolveValues } from "../demos/tune";
import { derive } from "./derive";
import { changesBetween, flatten, tuneSummary, tunedJsx, writeBrief } from "./brief";
import { printJsx } from "./print";
import { parseJsx, type PaperNode } from "./parse";

const welcome = readFileSync(new URL("./fixtures/welcome.jsx.txt", import.meta.url), "utf8");
const count = (node: PaperNode, match: (node: PaperNode) => boolean): number => (match(node) ? 1 : 0) + node.children.reduce<number>((sum, child) => sum + (typeof child === "string" ? 0 : count(child, match)), 0);

const tokens = [
  { name: "--color-ground", type: "color", value: "#F5F2EA" },
  { name: "--color-ink", type: "color", value: "#211F1A" },
  { name: "--font-ui", type: "fontFamily", value: "Inter" },
];

describe("parseJsx", () => {
  it("reads tags, attributes, styles and text", () => {
    const tree = parseJsx(`(
      <div style={{ color: 'var(--ink)', fontWeight: 600, 'margin': "1px" }} title="A &amp; B">
        Hello
        there {'  '}
        <svg width="10"><path d="M0 0" fillRule="evenodd" /></svg>
      </div>
    )`);
    expect(tree.tag).toBe("div");
    expect(tree.style).toEqual({ color: "var(--ink)", fontWeight: 600, margin: "1px" });
    expect(tree.attrs.title).toBe("A & B");
    expect(tree.children[0]).toBe("Hello there ");
    expect(tree.children[1]).toBe("  ");
    expect((tree.children[2] as PaperNode).tag).toBe("svg");
  });

  it("reads a whole real artboard from Paper", () => {
    const tree = parseJsx(welcome);
    expect(tree.tag).toBe("div");
    expect(tree.style.width).toBe("390px");
    expect(count(tree, () => true)).toBeGreaterThan(20);
    expect(count(tree, (node) => node.tag === "path")).toBeGreaterThan(0);
  });

  it("refuses anything that would have to run", () => {
    expect(() => parseJsx(`<div onClick={() => alert(1)} />`)).toThrow();
    expect(() => parseJsx(`<div>{items.map((x) => x)}</div>`)).toThrow();
    expect(() => parseJsx(`<div style={{ color: danger() }} />`)).toThrow();
    expect(() => parseJsx(`<div>`)).toThrow();
  });
});

describe("derive", () => {
  const tree = parseJsx(`<div style={{ backgroundColor: 'var(--color-ground)', fontFamily: 'var(--font-ui)', gap: '12px', padding: '16px 12px' }}>
    <div style={{ color: '#ff0000', fontSize: '17px', fontWeight: 600, borderRadius: '8px', backgroundColor: 'var(--color-ink)' }}>Save</div>
    <svg><path fill="#ff0000" d="M0 0" /></svg>
  </div>`);
  const derived = derive(tree, tokens);

  it("makes dials from the values the design really uses, set to those values", () => {
    const config = derived.config as Record<string, Record<string, unknown>>;
    expect(config.Colours.ground).toEqual({ type: "color", default: "#F5F2EA" });
    expect(config.Colours["#ff0000"]).toEqual({ type: "color", default: "#ff0000" });
    expect(config.Type["17 px"]).toEqual([17, 9, 34, 1]);
    expect(config.Spacing["12 px"]).toBeDefined();
    expect(config.Radius["8 px"]).toBeDefined();
    expect(config.Text["1. Save"]).toEqual({ type: "text", default: "Save" });
  });

  it("rewrites values to variables, and the stylesheet sets them back", () => {
    const button = derived.tree.children[0] as PaperNode;
    expect(button.style.fontSize).toMatch(/^var\(/);
    expect(button.style.color).toMatch(/^var\(/);
    const css = derived.css(resolveValues(derived.config));
    expect(css).toContain("--color-ground: #F5F2EA");
    expect(css).toContain("--paper-t-17: 17px");
    expect(css).toContain("--paper-w-600: 600");
    expect(css).toContain('--font-ui: "Inter"');
  });

  it("a dial changes what the stylesheet says", () => {
    const values = resolveValues(derived.config) as { Type: Record<string, number> };
    values.Type["17 px"] = 30;
    expect(derived.css(values)).toContain("--paper-t-17: 30px");
  });

  it("has no dial that does nothing", () => {
    const flat = (config: object, prefix = ""): string[] =>
      Object.entries(config).flatMap(([key, entry]) => (entry && typeof entry === "object" && !Array.isArray(entry) && !("type" in entry) ? flat(entry, `${prefix}${key}.`) : [`${prefix}${key}`]));
    const rest = resolveValues(derived.config) as Record<string, Record<string, unknown>>;
    const base = derived.css(rest);
    for (const path of flat(derived.config).filter((each) => !each.startsWith("Text."))) {
      const [folder, key] = path.split(".");
      const changed = structuredClone(rest);
      const value = changed[folder][key];
      changed[folder][key] = typeof value === "number" ? value + 0.5 : typeof value === "string" ? "#123456" : { type: "easing", duration: 0.77, ease: [0.1, 0.2, 0.3, 0.4] };
      expect(derived.css(changed), path).not.toBe(base);
    }
  });

  it("finds its motion: arrival always, press only on something pressable", () => {
    const css = derived.css(resolveValues(derived.config));
    expect(css).toContain("@keyframes paper-enter");
    expect(derived.hasPress).toBe(true);
    expect(css).toContain(".paper-press:active");
    const still = derive(parseJsx(`<div><div style={{ fontSize: '12px' }}>Plain words</div></div>`), []);
    expect(still.hasPress).toBe(false);
    expect(still.css(resolveValues(still.config))).not.toContain(".paper-press");
  });

  it("tells a dark design from a light one", () => {
    expect(derived.dark).toBe(false);
    const night = derive(parseJsx(`<div style={{ backgroundColor: '#0B0A09' }} />`), []);
    expect(night.dark).toBe(true);
  });

  it("gives a real artboard a usable panel", () => {
    const real = derive(parseJsx(welcome), tokens);
    const config = real.config as Record<string, Record<string, unknown>>;
    expect(Object.keys(config.Colours).length).toBeGreaterThan(0);
    expect(Object.keys(config.Motion).length).toBeGreaterThan(3);
    expect(() => real.css(resolveValues(real.config))).not.toThrow();
  });
});

describe("printing a design back out", () => {
  const tree = parseJsx(welcome);
  const record = { id: "paper/x", title: "Welcome", jsx: welcome, tokens: tokens, viewport: { w: 390, h: 844 }, source: { kind: "paper" as const, fileId: "f", fileName: "Greenhouse", nodeId: "n" } };

  it("reads back to the same tree", () => {
    expect(parseJsx(printJsx(tree))).toEqual(tree);
  });

  it("writes the tune into the design and leaves tokens as tokens", () => {
    const derived = derive(tree, tokens);
    const values = resolveValues(derived.config) as Record<string, Record<string, unknown>>;
    const size = Object.keys(values.Type).find((key) => key.endsWith(" px")) as string;
    const asDrawn = tunedJsx(record, values);
    expect(asDrawn).not.toContain("--paper-");
    expect(asDrawn).toContain("var(--font-");
    values.Type[size] = 99;
    expect(tunedJsx(record, values)).toContain('"99px"');
  });

  it("writes a tuned word in place of the drawn one", () => {
    const derived = derive(tree, tokens);
    const values = resolveValues(derived.config) as Record<string, Record<string, unknown>>;
    const first = Object.keys(values.Text)[0];
    values.Text[first] = "Changed words";
    expect(tunedJsx(record, values)).toContain("Changed words");
  });

  it("reports only what moved", () => {
    expect(changesBetween({ Type: { a: 1, b: 2 }, Motion: { enter: { type: "spring", damping: 30 } } }, { Type: { a: 1, b: 3 }, Motion: { enter: { type: "spring", damping: 40 } } })).toEqual([
      { dial: "Type.b", from: 2, to: 3 },
      { dial: "Motion.enter", from: { type: "spring", damping: 30 }, to: { type: "spring", damping: 40 } },
    ]);
  });

  it("doesn't count a value as moved because its keys came back in another order", () => {
    expect(changesBetween({ Motion: { enter: { type: "spring", damping: 30, mass: 1 } } }, { Motion: { enter: { mass: 1, damping: 30, type: "spring" } } })).toEqual([]);
  });

  it("says plainly when nothing was tuned, and lists a tune when something was", () => {
    const derived = derive(tree, tokens);
    const demo = { id: "paper/x", title: "Welcome", project: "paper", viewport: record.viewport, dials: { config: derived.config, css: derived.css } };
    const rest = writeBrief(demo, {}, record);
    expect(rest.changes).toEqual([]);
    expect(rest.markdown).toContain("Nothing. These are the values as designed.");
    expect(rest.dials.length).toBeGreaterThan(5);
    const dial = rest.dials.find((each) => each.startsWith("Type.") && each.endsWith(" px")) as string;
    const tuned = writeBrief(demo, { [dial]: 99 }, record);
    expect(tuned.markdown).toContain(`${dial}:`);
    expect(tuned.markdown).toContain("→ 99");
    expect(tuned.jsx).toContain('"99px"');
  });

  it("puts the person's note in the brief, and leaves the heading out when there isn't one", () => {
    const derived = derive(tree, tokens);
    const demo = { id: "paper/x", title: "Welcome", project: "paper", viewport: record.viewport, dials: { config: derived.config, css: derived.css } };
    expect(writeBrief(demo, {}, record).markdown).not.toContain("What the person wants");
    expect(writeBrief(demo, {}, record, "   ").markdown).not.toContain("What the person wants");
    expect(writeBrief(demo, {}, record, "Tighter radius").markdown).toContain("## What the person wants\n\nTighter radius");
  });

  it("gives the same tune the same key, whatever order it comes back in", () => {
    const derived = derive(tree, tokens);
    const dial = Object.keys(flatten(resolveValues(derived.config, {}) as Record<string, unknown>)).find((each) => each.startsWith("Type.")) as string;
    const rest = tuneSummary(derived.config, {});
    expect(rest.changes).toEqual([]);
    expect(rest.key).toBe("[]");
    const first = tuneSummary(derived.config, { [dial]: 99, "Motion.stagger": 10 });
    const second = tuneSummary(derived.config, { "Motion.stagger": 10, [dial]: 99 });
    expect(first.changes).toHaveLength(2);
    expect(first.key).toBe(second.key);
    expect(tuneSummary(derived.config, { [dial]: 98, "Motion.stagger": 10 }).key).not.toBe(first.key);
  });
});
