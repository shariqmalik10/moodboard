import postcss from "postcss";
import ts from "typescript";
import type { Format, Literal } from "./types.ts";

const SPACING = new Set(["p", "px", "py", "pt", "pr", "pb", "pl", "ps", "pe", "m", "mx", "my", "mt", "mr", "mb", "ml", "ms", "me", "gap", "gap-x", "gap-y", "w", "h", "size", "min-w", "min-h", "max-w", "max-h", "top", "right", "bottom", "left", "inset", "inset-x", "inset-y", "space-x", "space-y", "translate-x", "translate-y"]);
const LABELS: Record<string, string> = { p: "padding", px: "padding x", py: "padding y", pt: "padding top", pr: "padding right", pb: "padding bottom", pl: "padding left", ps: "padding start", pe: "padding end", m: "margin", mx: "margin x", my: "margin y", mt: "margin top", mr: "margin right", mb: "margin bottom", ml: "margin left", ms: "margin start", me: "margin end", gap: "gap", "gap-x": "gap x", "gap-y": "gap y", w: "width", h: "height", size: "size", "min-w": "min width", "min-h": "min height", "max-w": "max width", "max-h": "max height", top: "top", right: "right", bottom: "bottom", left: "left", inset: "inset", "inset-x": "inset x", "inset-y": "inset y", "space-x": "space x", "space-y": "space y", "translate-x": "move x", "translate-y": "move y", rounded: "radius", "rounded-t": "radius top", "rounded-b": "radius bottom", "rounded-l": "radius left", "rounded-r": "radius right", "rounded-tl": "radius top left", "rounded-tr": "radius top right", "rounded-bl": "radius bottom left", "rounded-br": "radius bottom right", text: "text size", leading: "line height", tracking: "tracking", opacity: "opacity", duration: "duration", delay: "delay", scale: "scale", rotate: "rotate", border: "border", "border-t": "border top", "border-b": "border bottom", "border-l": "border left", "border-r": "border right", blur: "blur", bg: "background", "text-color": "text colour", "border-color": "border colour" };
const RADIUS: Record<string, number> = { none: 0, xs: 2, sm: 4, md: 6, lg: 8, xl: 12, "2xl": 16, "3xl": 24, "4xl": 32 };
const TEXT: Record<string, number> = { xs: 12, sm: 14, base: 16, lg: 18, xl: 20, "2xl": 24, "3xl": 30, "4xl": 36, "5xl": 48, "6xl": 60, "7xl": 72 };
const RADIUS_PREFIXES = new Set(["rounded", "rounded-t", "rounded-b", "rounded-l", "rounded-r", "rounded-tl", "rounded-tr", "rounded-bl", "rounded-br"]);
const PLAIN = new Set(["opacity", "duration", "delay", "scale", "rotate"]);
const ARBITRARY_ONLY = new Set(["leading", "tracking", "border", "border-t", "border-b", "border-l", "border-r", "blur"]);
const COLOR_PREFIXES = new Set(["bg", "text", "border", "fill", "stroke", "ring", "outline", "shadow", "from", "to", "via"]);
const HEX = /^#[0-9a-fA-F]{3,8}$/;
const MOTION_ATTRIBUTES = new Set(["animate", "initial", "exit", "whileHover", "whileTap", "whileFocus", "whileInView", "transition", "style"]);
const NUMBER = /^(-?\d*\.?\d+)([a-z%]*)$/;

const round = (value: number, step: number) => Number((Math.round(value / step) * step).toFixed(4));

function rangeFor(prefix: string, value: number, unit: string): { min: number; max: number; step: number } {
  // A slider snaps to its step, so a value like 1.15 or 0.3 needs a step that can hold it.
  if (!Number.isInteger(value) && Math.abs(value) < 4) return { min: Math.min(0, value * 2), max: Math.max(2, value * 3), step: 0.01 };
  if (unit === "em" || unit === "rem") return { min: Math.min(0, value), max: Math.max(4, value * 3), step: 0.01 };
  if (unit === "s") return { min: 0, max: Math.max(2, value * 3), step: 0.01 };
  if (unit === "ms" || prefix === "duration" || prefix === "delay") return { min: 0, max: Math.max(2000, value * 3), step: 10 };
  if (prefix === "opacity") return { min: 0, max: 100, step: 1 };
  if (prefix === "scale") return { min: 0, max: Math.max(200, value * 2), step: 1 };
  if (prefix === "rotate") return { min: -180, max: 180, step: 1 };
  if (prefix === "text") return { min: 8, max: Math.max(96, value * 2), step: 1 };
  if (RADIUS_PREFIXES.has(prefix)) return { min: 0, max: Math.max(64, value * 2), step: 1 };
  if (prefix === "leading") return { min: 0, max: Math.max(80, value * 2), step: 1 };
  return { min: Math.min(0, value * 2), max: Math.max(96, value * 2), step: 1 };
}

/** What one Tailwind class means as a dial, when it's a plain value on the default scale or a written-out value. */
export function readToken(token: string): { variant: string; prefix: string; dial: Literal["dial"]; format: Format; suffixStart: number } | null {
  const colon = token.lastIndexOf(":", token.includes("[") ? token.indexOf("[") : token.length);
  const variant = colon >= 0 ? token.slice(0, colon) : "";
  let rest = colon >= 0 ? token.slice(colon + 1) : token;
  let offset = colon + 1;
  if (rest.startsWith("!")) {
    rest = rest.slice(1);
    offset += 1;
  }
  const negative = rest.startsWith("-");
  if (negative) {
    rest = rest.slice(1);
    offset += 1;
  }
  const sign = negative ? -1 : 1;
  const arbitrary = rest.match(/^([a-z-]+?)-\[([^\]]+)\]$/);
  if (arbitrary) {
    const prefix = arbitrary[1] ?? "";
    const inner = arbitrary[2] ?? "";
    if (HEX.test(inner) && COLOR_PREFIXES.has(prefix)) return { variant, prefix: prefix === "text" ? "text-color" : prefix === "border" ? "border-color" : prefix, dial: { kind: "color", value: inner }, format: { kind: "tailwindColor", prefix }, suffixStart: offset };
    const number = inner.match(NUMBER);
    if (!number || !(SPACING.has(prefix) || RADIUS_PREFIXES.has(prefix) || PLAIN.has(prefix) || ARBITRARY_ONLY.has(prefix) || prefix === "text")) return null;
    const value = Number(number[1]) * sign;
    const unit = number[2] ?? "";
    return { variant, prefix, dial: { kind: "number", value, ...rangeFor(prefix, value, unit) }, format: { kind: "tailwind", prefix, family: "arbitrary", unit, negative: false }, suffixStart: offset - (negative ? 1 : 0) };
  }
  const dash = rest.lastIndexOf("-");
  if (dash <= 0) return null;
  const prefix = rest.slice(0, dash);
  const name = rest.slice(dash + 1);
  if (SPACING.has(prefix) && /^\d*\.?\d+$/.test(name)) {
    const value = Number(name) * 4 * sign;
    return { variant, prefix, dial: { kind: "number", value, ...rangeFor(prefix, value, "px") }, format: { kind: "tailwind", prefix, family: "spacing", unit: "px", negative: false }, suffixStart: offset - (negative ? 1 : 0) };
  }
  if (RADIUS_PREFIXES.has(prefix) && name in RADIUS) {
    const value = RADIUS[name] ?? 0;
    return { variant, prefix, dial: { kind: "number", value, ...rangeFor(prefix, value, "px") }, format: { kind: "tailwind", prefix, family: "radius", unit: "px", negative: false }, suffixStart: offset };
  }
  if (prefix === "text" && name in TEXT) {
    const value = TEXT[name] ?? 16;
    return { variant, prefix, dial: { kind: "number", value, ...rangeFor(prefix, value, "px") }, format: { kind: "tailwind", prefix, family: "text", unit: "px", negative: false }, suffixStart: offset };
  }
  if (PLAIN.has(prefix) && /^\d+$/.test(name)) {
    const value = Number(name) * sign;
    return { variant, prefix, dial: { kind: "number", value, ...rangeFor(prefix, value, "") }, format: { kind: "tailwind", prefix, family: "plain", unit: "", negative: false }, suffixStart: offset - (negative ? 1 : 0) };
  }
  if (rest === "rounded") return { variant, prefix: "rounded", dial: { kind: "number", value: 4, ...rangeFor("rounded", 4, "px") }, format: { kind: "tailwind", prefix: "rounded", family: "radius", unit: "px", negative: false }, suffixStart: offset };
  return null;
}

/** The source text a dial value becomes. Stays on the project's scale when the value is on it. */
export function formatValue(format: Format, value: number | string): string {
  switch (format.kind) {
    case "tailwindColor":
      return `${format.prefix}-[${value}]`;
    case "number":
      return String(value);
    case "unit":
      return `${value}${format.unit}`;
    case "stringUnit":
      return `${format.quote}${value}${format.unit}${format.quote}`;
    case "color":
      return `${format.quote}${value}${format.quote}`;
    case "tailwind": {
      const number = Number(value);
      const minus = number < 0 ? "-" : "";
      const size = Math.abs(number);
      if (format.family === "spacing" && (size % 4 === 0 || (size < 16 && size % 2 === 0))) return `${minus}${format.prefix}-${size / 4}`;
      if (format.family === "radius") {
        const name = Object.entries(RADIUS).find(([, each]) => each === size)?.[0];
        if (name) return `${format.prefix}-${name}`;
      }
      if (format.family === "text") {
        const name = Object.entries(TEXT).find(([, each]) => each === size)?.[0];
        if (name) return `text-${name}`;
      }
      if (format.family === "plain") return `${minus}${format.prefix}-${size}`;
      const unit = format.family === "arbitrary" ? format.unit : "px";
      return `${format.prefix}-[${number}${unit}]`;
    }
  }
}

type Sink = { add: (group: string, label: string, literal: Omit<Literal, "path">) => void };

function makeSink() {
  const out: Literal[] = [];
  const used = new Map<string, number>();
  const sink: Sink = {
    add(group, label, literal) {
      const clean = (text: string) => text.replace(/\./g, "·");
      const base = `${clean(group)}.${clean(label)}`;
      const count = (used.get(base) ?? 0) + 1;
      used.set(base, count);
      out.push({ ...literal, path: count > 1 ? `${base} ${count}` : base });
    },
  };
  return { out, sink };
}

/** Finds the exported component's own code, so a file with several components gives each only its own dials. */
function componentNode(source: ts.SourceFile, exportName: string): ts.Node {
  let found: ts.Node | undefined;
  let target = exportName;
  if (exportName === "default") {
    for (const statement of source.statements) {
      if (ts.isExportAssignment(statement)) {
        if (ts.isIdentifier(statement.expression)) target = statement.expression.text;
        else found = statement.expression;
      }
      if (ts.isFunctionDeclaration(statement) && ts.getModifiers(statement)?.some((each) => each.kind === ts.SyntaxKind.DefaultKeyword)) found = statement;
    }
  }
  if (!found) {
    for (const statement of source.statements) {
      if (ts.isFunctionDeclaration(statement) && statement.name?.text === target) found = statement;
      if (ts.isVariableStatement(statement)) {
        for (const each of statement.declarationList.declarations) {
          if (ts.isIdentifier(each.name) && each.name.text === target) found = each;
        }
      }
    }
  }
  return found ?? source;
}

function classStrings(node: ts.Expression): ts.StringLiteralLike[] {
  if (ts.isStringLiteralLike(node)) return [node];
  if (ts.isJsxExpression(node) && node.expression) return classStrings(node.expression);
  if (ts.isParenthesizedExpression(node)) return classStrings(node.expression);
  if (ts.isConditionalExpression(node)) return [...classStrings(node.whenTrue), ...classStrings(node.whenFalse)];
  if (ts.isBinaryExpression(node)) return [...classStrings(node.left), ...classStrings(node.right)];
  if (ts.isCallExpression(node) && ts.isIdentifier(node.expression) && /^(cn|clsx|classNames|cx|twMerge)$/.test(node.expression.text)) return node.arguments.flatMap(classStrings);
  if (ts.isArrayLiteralExpression(node)) return node.elements.flatMap(classStrings);
  return [];
}

function tagOf(node: ts.JsxAttribute, source: ts.SourceFile) {
  const opening = node.parent.parent;
  return ts.isJsxOpeningElement(opening) || ts.isJsxSelfClosingElement(opening) ? opening.tagName.getText(source) : "element";
}

function readObject(object: ts.ObjectLiteralExpression, source: ts.SourceFile, file: string, group: string, trail: string, sink: Sink) {
  for (const property of object.properties) {
    if (!ts.isPropertyAssignment(property)) continue;
    const key = property.name.getText(source).replace(/["']/g, "");
    const label = trail ? `${trail} ${key}` : key;
    const value = property.initializer;
    if (ts.isObjectLiteralExpression(value)) {
      readObject(value, source, file, group, label, sink);
    } else if (ts.isNumericLiteral(value) || (ts.isPrefixUnaryExpression(value) && value.operator === ts.SyntaxKind.MinusToken && ts.isNumericLiteral(value.operand))) {
      const number = Number(value.getText(source));
      const isDuration = /duration|delay/i.test(key);
      const range = isDuration ? { min: 0, max: Math.max(2, number * 3), step: 0.01 } : /scale|opacity/i.test(key) ? { min: 0, max: Math.max(2, number * 2), step: 0.01 } : /stiffness|damping|mass/i.test(key) ? { min: 0, max: Math.max(800, number * 2), step: 1 } : { min: Math.min(0, number * 2), max: Math.max(100, number * 2), step: 1 };
      sink.add(group, label, { file, start: value.getStart(source), end: value.getEnd(), text: value.getText(source), dial: { kind: "number", value: number, ...range }, format: { kind: "number" } });
    } else if (ts.isStringLiteralLike(value)) {
      const quote = source.text.charAt(value.getStart(source));
      if (HEX.test(value.text)) sink.add(group, label, { file, start: value.getStart(source), end: value.getEnd(), text: value.getText(source), dial: { kind: "color", value: value.text }, format: { kind: "color", quote } });
      const number = value.text.match(NUMBER);
      if (number) {
        const amount = Number(number[1]);
        const unit = number[2] ?? "";
        sink.add(group, label, { file, start: value.getStart(source), end: value.getEnd(), text: value.getText(source), dial: { kind: "number", value: amount, ...rangeFor(key, amount, unit) }, format: { kind: "stringUnit", quote, unit } });
      }
    }
  }
}

/** The dials for one component's own file, and the class names its elements use so its CSS rules can be found. */
export function readComponent(text: string, file: string, exportName: string): { literals: Literal[]; classes: Set<string> } {
  const source = ts.createSourceFile(file, text, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);
  const { out, sink } = makeSink();
  const classes = new Set<string>();
  const tags = new Map<string, number>();
  const groups = new Map<ts.Node, string>();
  const groupFor = (node: ts.JsxAttribute) => {
    const opening = node.parent.parent;
    const known = groups.get(opening);
    if (known) return known;
    const tag = tagOf(node, source);
    const count = (tags.get(tag) ?? 0) + 1;
    tags.set(tag, count);
    const group = count > 1 ? `${tag} ${count}` : tag;
    groups.set(opening, group);
    return group;
  };
  const visit = (node: ts.Node) => {
    if (ts.isJsxAttribute(node) && node.initializer) {
      const name = node.name.getText(source);
      if (name === "className") {
        const expression = ts.isJsxExpression(node.initializer) ? node.initializer.expression : node.initializer;
        if (expression) {
          for (const literal of classStrings(expression)) {
            const group = groupFor(node);
            const inner = literal.getStart(source) + 1;
            const pattern = /\S+/g;
            for (const match of literal.text.matchAll(pattern)) {
              const token = match[0];
              const read = readToken(token);
              if (!read) {
                classes.add(token);
                continue;
              }
              // Only the part after a variant changes, so `md:p-4` keeps its `md:`.
              const start = inner + (match.index ?? 0) + read.suffixStart;
              const end = inner + (match.index ?? 0) + token.length;
              const label = `${read.variant ? `${read.variant}: ` : ""}${LABELS[read.prefix] ?? read.prefix}`;
              sink.add(group, label, { file, start, end, text: token.slice(read.suffixStart), dial: read.dial, format: read.format });
            }
          }
        }
      } else if (MOTION_ATTRIBUTES.has(name) && ts.isJsxExpression(node.initializer) && node.initializer.expression && ts.isObjectLiteralExpression(node.initializer.expression)) {
        readObject(node.initializer.expression, source, file, groupFor(node), name === "style" ? "" : name, sink);
      }
    }
    ts.forEachChild(node, visit);
  };
  visit(componentNode(source, exportName));
  return { literals: out, classes };
}

/** Dials for every CSS rule that names one of the component's classes. */
export function readCss(text: string, file: string, classes: Set<string>, into: Literal[]) {
  if (classes.size === 0) return;
  const { out, sink } = makeSink();
  let root: postcss.Root;
  try {
    root = postcss.parse(text, { from: file });
  } catch {
    return;
  }
  root.walkRules((rule) => {
    const names = [...rule.selector.matchAll(/\.([A-Za-z0-9_-]+)/g)].map((each) => each[1] ?? "");
    if (!names.some((each) => classes.has(each))) return;
    const group = rule.selector.replace(/\s+/g, " ").slice(0, 48);
    rule.each((node) => {
      if (node.type !== "decl" || !node.source?.start) return;
      const value = node.value;
      if (/var\(|calc\(|url\(/.test(value)) return;
      const startOfValue = (node.source.start.offset ?? 0) + node.toString().indexOf(value, node.prop.length);
      if (HEX.test(value)) {
        sink.add(group, node.prop, { file, start: startOfValue, end: startOfValue + value.length, text: value, dial: { kind: "color", value }, format: { kind: "color", quote: "" } });
        return;
      }
      for (const match of value.matchAll(/-?\d*\.?\d+(px|rem|em|ms|s|%)?(?![\w-])/g)) {
        const piece = match[0];
        const number = piece.match(NUMBER);
        if (!number) continue;
        const amount = Number(number[1]);
        const unit = number[2] ?? "";
        const at = startOfValue + (match.index ?? 0);
        const count = value.match(/-?\d*\.?\d+(px|rem|em|ms|s|%)?(?![\w-])/g)?.length ?? 1;
        sink.add(group, count > 1 ? `${node.prop} ${unit || "value"}` : node.prop, { file, start: at, end: at + piece.length, text: piece, dial: { kind: "number", value: amount, ...rangeFor(node.prop, amount, unit) }, format: { kind: "unit", unit } });
      }
    });
  });
  into.push(...out);
}

/** The DialKit panel these literals make, in the panel's own shape. */
export function dialConfig(literals: Literal[]): Record<string, Record<string, unknown>> {
  const config: Record<string, Record<string, unknown>> = {};
  for (const literal of literals) {
    const dot = literal.path.indexOf(".");
    const group = literal.path.slice(0, dot);
    const label = literal.path.slice(dot + 1);
    const folder = (config[group] ??= {});
    folder[label] = literal.dial.kind === "color" ? { type: "color", default: literal.dial.value } : [round(literal.dial.value, literal.dial.step), literal.dial.min, literal.dial.max, literal.dial.step];
  }
  return config;
}

/** Applies new values to one file's text. Later positions go first so earlier ones stay true. */
export function applyEdits(text: string, edits: { start: number; end: number; next: string }[]) {
  let out = text;
  for (const edit of [...edits].sort((a, b) => b.start - a.start)) out = out.slice(0, edit.start) + edit.next + out.slice(edit.end);
  return out;
}
