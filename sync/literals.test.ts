import { describe, expect, it } from "vitest";
import { applyEdits, dialConfig, formatValue, readComponent, readCss, readToken } from "./literals.ts";

describe("reading a Tailwind class as a dial", () => {
  it("reads a scale value in pixels", () => {
    const token = readToken("p-4");
    expect(token?.dial).toMatchObject({ kind: "number", value: 16 });
  });

  it("reads a written-out value and a variant", () => {
    const token = readToken("md:rounded-[18px]");
    expect(token?.variant).toBe("md");
    expect(token?.dial).toMatchObject({ kind: "number", value: 18 });
  });

  it("reads a colour", () => {
    expect(readToken("bg-[#334455]")?.dial).toEqual({ kind: "color", value: "#334455" });
  });

  it("leaves alone what isn't a value", () => {
    expect(readToken("flex")).toBeNull();
    expect(readToken("text-center")).toBeNull();
  });

  it("gives a fractional value a step that can hold it, so the slider doesn't round it on load", () => {
    const token = readToken("leading-[1.15]");
    expect(token?.dial).toMatchObject({ value: 1.15, step: 0.01 });
  });
});

describe("writing a value back", () => {
  it("stays on the scale when the value is on it", () => {
    const token = readToken("p-4");
    if (!token) throw new Error("no token");
    expect(formatValue(token.format, 20)).toBe("p-5");
  });

  it("goes off the scale when the value isn't on it", () => {
    const token = readToken("p-4");
    if (!token) throw new Error("no token");
    expect(formatValue(token.format, 18)).toBe("p-[18px]");
  });

  it("keeps the half steps Tailwind's scale has", () => {
    const token = readToken("gap-1.5");
    if (!token) throw new Error("no token");
    expect(token.dial).toMatchObject({ value: 6 });
    expect(formatValue(token.format, 6)).toBe("gap-1.5");
  });

  it("keeps the unit of a written-out value", () => {
    const token = readToken("rounded-[18px]");
    if (!token) throw new Error("no token");
    expect(formatValue(token.format, 31)).toBe("rounded-[31px]");
  });

  it("replaces only the literal in a real component", () => {
    const text = `export function Card() { return <div className="rounded-[18px] flex p-4">Hi</div>; }\n`;
    const { literals } = readComponent(text, "/x/Card.tsx", "Card");
    const radius = literals.find((each) => each.path.endsWith("radius"));
    if (!radius) throw new Error("no radius dial");
    expect(text.slice(radius.start, radius.end)).toBe(radius.text);
    const after = applyEdits(text, [{ start: radius.start, end: radius.end, next: formatValue(radius.format, 40) }]);
    expect(after).toBe(text.replace("rounded-[18px]", "rounded-[40px]"));
  });

  it("applies several edits to one file without their offsets disturbing each other", () => {
    expect(applyEdits("aa bb cc", [{ start: 0, end: 2, next: "xxxx" }, { start: 6, end: 8, next: "y" }])).toBe("xxxx bb y");
  });
});

describe("what counts as this component's", () => {
  const two = `export function A() { return <div className="p-4" />; }\nexport function B() { return <div className="p-8" />; }\n`;

  it("reads only the export asked for", () => {
    const { literals } = readComponent(two, "/x/two.tsx", "B");
    expect(literals.map((each) => each.text)).toEqual(["p-8"]);
  });

  it("reads classes inside cn() and conditionals", () => {
    const text = `export function C({ on }: { on: boolean }) { return <div className={cn("p-4", on ? "m-2" : "m-3")} />; }\n`;
    expect(readComponent(text, "/x/c.tsx", "C").literals.map((each) => each.text).sort()).toEqual(["m-2", "m-3", "p-4"]);
  });

  it("finds a CSS rule that names a class the component uses, at its real offset", () => {
    const text = `export function D() { return <div className="card" />; }\n`;
    const { classes, literals } = readComponent(text, "/x/d.tsx", "D");
    const css = `.other { padding: 1px; }\n.card { padding: 12px; color: #112233; }\n`;
    readCss(css, "/x/d.css", classes, literals);
    expect(literals.length).toBeGreaterThan(0);
    for (const each of literals) expect(css.slice(each.start, each.end)).toBe(each.text);
    expect(literals.some((each) => each.text.includes("1px"))).toBe(false);
  });

  it("nests each dial under its group in the panel's config", () => {
    const { literals } = readComponent(`export function E() { return <div className="p-4" />; }\n`, "/x/e.tsx", "E");
    expect(Object.keys(dialConfig(literals))).toHaveLength(1);
  });
});
