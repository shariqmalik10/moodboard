import type { DialConfig } from "dialkit";
import { curve } from "../demos/tune";
import type { PaperNode, PaperValue } from "./parse";

export type PaperToken = { name: string; type: string; value: string; description?: string };

export type PaperRecord = {
  id: string;
  title: string;
  jsx: string;
  tokens: PaperToken[];
  viewport: { w: number; h: number };
  source: { kind: "paper"; fileId: string; fileName?: string; nodeId: string };
};

type Binding = { folder: string; key: string; cssVar: string; unit: string };

export type Derived = {
  tree: PaperNode;
  config: DialConfig;
  css: (values: Record<string, unknown>) => string;
  /** What each dial's CSS variable holds under this tune. */
  vars: (values: Record<string, unknown>) => Record<string, string>;
  ground: string;
  dark: boolean;
  fonts: string[];
  texts: string[];
  hasPress: boolean;
};

const COLOR_KEYS = new Set(["color", "backgroundColor", "borderColor", "borderTopColor", "borderRightColor", "borderBottomColor", "borderLeftColor", "outlineColor", "fill", "stroke"]);
const SPACE_KEYS = new Set(["gap", "rowGap", "columnGap", "padding", "paddingTop", "paddingRight", "paddingBottom", "paddingLeft", "paddingInline", "paddingBlock", "margin", "marginTop", "marginRight", "marginBottom", "marginLeft"]);
const COLOR_LITERAL = /^(#[\da-f]{3,8}|rgba?\(.+\)|hsla?\(.+\)|oklch\(.+\)|color\(.+\))$/i;
const PLAIN = new Set(["none", "transparent", "currentColor", "currentcolor", "inherit"]);
const MAX = { colors: 14, sizes: 8, weights: 4, spaces: 8, radii: 4, texts: 12 };

const slug = (text: string) => text.replace(/^--/, "").replace(/[^\w-]+/g, "-");
const tokenOf = (value: string) => /^var\((--[\w-]+)(?:,.*)?\)$/.exec(value)?.[1];

function walk(node: PaperNode, visit: (node: PaperNode) => void) {
  visit(node);
  for (const child of node.children) if (typeof child !== "string") walk(child, visit);
}

/** Counts each distinct value, most used first, so the dials a design needs most are the ones it gets. */
function ranked(values: string[], limit: number) {
  const counts = new Map<string, number>();
  for (const value of values) counts.set(value, (counts.get(value) ?? 0) + 1);
  return [...counts.entries()].sort((a, b) => b[1] - a[1]).slice(0, limit).map(([value]) => value);
}

const px = (value: PaperValue) => (typeof value === "number" ? value : /^-?[\d.]+px$/.test(value) ? Number.parseFloat(value) : null);

function hexOf(value: string) {
  const match = /^#([\da-f]{6}|[\da-f]{3})/i.exec(value);
  if (!match) return null;
  return match[1].length === 3 ? [...match[1]].map((c) => c + c).join("") : match[1];
}

function isDark(value: string) {
  const hex = hexOf(value);
  if (!hex) return false;
  const [r, g, b] = [0, 2, 4].map((at) => Number.parseInt(hex.slice(at, at + 2), 16) / 255);
  return 0.2126 * r + 0.7152 * g + 0.0722 * b < 0.45;
}

function looksPressable(node: PaperNode) {
  if (node.tag !== "div") return false;
  const filled = Boolean(node.style.backgroundColor || node.style.borderColor || node.style.boxShadow);
  const rounded = px(node.style.borderRadius ?? "") !== null;
  const text = node.children.filter((child): child is PaperNode => typeof child !== "string").flatMap((child) => child.children).filter((child) => typeof child === "string");
  const label = [...node.children, ...text].filter((child) => typeof child === "string").join(" ");
  const height = px(node.style.height ?? "");
  return filled && rounded && label.length > 0 && label.length < 28 && (height === null || height < 72);
}

/**
 * Turns a design into something tunable: it rewrites the design's own values to CSS variables and makes
 * a dial for each, using only values that are really there. Paths come from a token's name or the value
 * itself, so a tune survives a fresh import of the same design.
 */
export function derive(tree: PaperNode, tokens: PaperToken[]): Derived {
  const tokenValues = new Map(tokens.map((token) => [token.name, token.value]));
  const resolve = (value: string) => {
    const name = tokenOf(value);
    return name ? (tokenValues.get(name) ?? value) : value;
  };

  const colours: string[] = [];
  const sizes: string[] = [];
  const weights: string[] = [];
  const spaces: string[] = [];
  const radii: string[] = [];
  const texts: string[] = [];
  const families = new Set<string>();

  walk(tree, (node) => {
    for (const [key, value] of [...Object.entries(node.style), ...Object.entries(node.attrs)]) {
      if (typeof value === "string" && COLOR_KEYS.has(key) && !PLAIN.has(value) && (tokenOf(value) || COLOR_LITERAL.test(value))) colours.push(value);
      if (key === "fontSize" && px(value) !== null) sizes.push(String(px(value)));
      if (key === "fontWeight" && !Number.isNaN(Number(value))) weights.push(String(value));
      if (SPACE_KEYS.has(key) && typeof value === "string") {
        for (const part of value.split(/\s+/)) if (px(part) !== null && px(part) !== 0) spaces.push(String(px(part)));
      }
      if (key === "borderRadius" && px(value) !== null && px(value) !== 0) radii.push(String(px(value)));
      if (key === "fontFamily") {
        for (const family of resolve(String(value)).split(",")) {
          const name = family.trim().replace(/^["']|["']$/g, "");
          if (name && !/^(system-ui|sans-serif|serif|monospace|ui-|-apple)/.test(name)) families.add(name);
        }
      }
    }
    for (const child of node.children) {
      if (typeof child === "string" && child.trim() && texts.length < MAX.texts) texts.push(child);
    }
  });

  const config: Record<string, unknown> = {};
  const bindings: Binding[] = [];
  const colorVar = new Map<string, string>();
  const sizeVar = new Map<string, string>();
  const weightVar = new Map<string, string>();
  const spaceVar = new Map<string, string>();
  const radiusVar = new Map<string, string>();

  const folder = (name: string) => (config[name] ??= {}) as Record<string, unknown>;

  for (const value of ranked(colours, MAX.colors)) {
    const token = tokenOf(value);
    const key = token ? slug(token).replace(/^color-/, "") : `#${(hexOf(value) ?? slug(value)).toLowerCase()}`;
    const cssVar = token ?? `--paper-c-${slug(key.replace("#", ""))}`;
    const rest = resolve(value);
    folder("Colours")[key] = { type: "color", default: hexOf(rest) ? `#${hexOf(rest)}` : rest };
    bindings.push({ folder: "Colours", key, cssVar, unit: "" });
    colorVar.set(value, `var(${cssVar})`);
  }
  for (const value of ranked(sizes, MAX.sizes).sort((a, b) => Number(b) - Number(a))) {
    const n = Number(value);
    const key = `${value} px`;
    const cssVar = `--paper-t-${slug(value)}`;
    folder("Type")[key] = [n, Math.max(6, Math.round(n * 0.5)), Math.round(n * 2), 1];
    bindings.push({ folder: "Type", key, cssVar, unit: "px" });
    sizeVar.set(value, `var(${cssVar})`);
  }
  for (const value of ranked(weights, MAX.weights).sort((a, b) => Number(a) - Number(b))) {
    const key = `Weight ${value}`;
    const cssVar = `--paper-w-${value}`;
    folder("Type")[key] = [Number(value), 100, 900, 100];
    bindings.push({ folder: "Type", key, cssVar, unit: "" });
    weightVar.set(value, `var(${cssVar})`);
  }
  for (const value of ranked(spaces, MAX.spaces).sort((a, b) => Number(a) - Number(b))) {
    const n = Number(value);
    const key = `${value} px`;
    const cssVar = `--paper-s-${slug(value)}`;
    folder("Spacing")[key] = [n, 0, Math.max(n * 3, 48), 1];
    bindings.push({ folder: "Spacing", key, cssVar, unit: "px" });
    spaceVar.set(value, `var(${cssVar})`);
  }
  for (const value of ranked(radii, MAX.radii).sort((a, b) => Number(a) - Number(b))) {
    const n = Number(value);
    const key = `${value} px`;
    const cssVar = `--paper-r-${slug(value)}`;
    folder("Radius")[key] = [n, 0, Math.max(n * 3, 40), 1];
    bindings.push({ folder: "Radius", key, cssVar, unit: "px" });
    radiusVar.set(value, `var(${cssVar})`);
  }
  if (texts.length > 0) {
    const words = folder("Text");
    texts.forEach((text, at) => {
      words[`${at + 1}. ${text.slice(0, 18)}`] = { type: "text", default: text };
    });
  }

  let hasPress = false;
  const rewrite = (node: PaperNode): PaperNode => {
    const style: Record<string, PaperValue> = {};
    for (const [key, value] of Object.entries(node.style)) {
      const number = px(value);
      if (key === "fontSize" && number !== null && sizeVar.has(String(number))) style[key] = sizeVar.get(String(number)) as string;
      else if (key === "fontWeight" && weightVar.has(String(value))) style[key] = weightVar.get(String(value)) as string;
      else if (key === "borderRadius" && number !== null && radiusVar.has(String(number))) style[key] = radiusVar.get(String(number)) as string;
      else if (typeof value === "string" && COLOR_KEYS.has(key) && colorVar.has(value)) style[key] = colorVar.get(value) as string;
      else if (typeof value === "string" && SPACE_KEYS.has(key)) style[key] = value.split(/\s+/).map((part) => spaceVar.get(String(px(part))) ?? part).join(" ");
      else style[key] = value;
    }
    const attrs: Record<string, PaperValue> = {};
    for (const [key, value] of Object.entries(node.attrs)) {
      attrs[key] = typeof value === "string" && COLOR_KEYS.has(key) && colorVar.has(value) ? (colorVar.get(value) as string) : value;
    }
    if (looksPressable(node)) {
      hasPress = true;
      attrs.className = "paper-press";
    }
    return { ...node, style, attrs, children: node.children.map((child) => (typeof child === "string" ? child : rewrite(child))) };
  };
  const rewritten = rewrite(tree);

  // Static designs get real motion to tune: how they arrive, and how their controls answer a press.
  const motion: Record<string, unknown> = {
    enter: { type: "spring", stiffness: 260, damping: 30, mass: 1 },
    stagger: [55, 0, 200, 5],
    rise: [14, 0, 60, 1],
    settle: [0.985, 0.9, 1, 0.005],
  };
  if (hasPress) {
    motion.press = { type: "easing", duration: 0.14, ease: [0.2, 0.8, 0.2, 1] };
    motion.hoverLift = [1.02, 1, 1.1, 0.005];
    motion.pressDown = [0.97, 0.88, 1, 0.005];
  }
  config.Motion = motion;

  const ground = resolve(String(tree.style.backgroundColor ?? "#f4f5f1"));
  const tokenLines = tokens.filter((token) => !bindings.some((binding) => binding.cssVar === token.name)).map((token) => `${token.name}: ${fontValue(token)};`);

  const vars = (values: Record<string, unknown>) => {
    const out: Record<string, string> = {};
    for (const binding of bindings) {
      const value = (values[binding.folder] as Record<string, unknown> | undefined)?.[binding.key];
      if (value !== undefined) out[binding.cssVar] = `${value}${binding.unit}`;
    }
    return out;
  };

  const css = (values: Record<string, unknown>) => {
    const lines = [...tokenLines, ...Object.entries(vars(values)).map(([name, value]) => `${name}: ${value};`)];
    const tuned = (values.Motion ?? {}) as Record<string, never>;
    const enter = curve(tuned.enter);
    let out = `:root { ${lines.join(" ")} }\n`;
    out += `.paper-root > * > * { animation: paper-enter ${enter.ms}ms ${enter.ease} both; animation-delay: calc(var(--paper-i, 0) * ${tuned.stagger}ms); }\n`;
    out += `@keyframes paper-enter { from { opacity: 0; transform: translateY(${tuned.rise}px) scale(${tuned.settle}); } }\n`;
    if (hasPress) {
      const press = curve(tuned.press);
      out += `.paper-press { transition: transform ${press.ms}ms ${press.ease}; }\n`;
      out += `.paper-press:hover { transform: scale(${tuned.hoverLift}); }\n`;
      out += `.paper-press:active { transform: scale(${tuned.pressDown}); }\n`;
    }
    return out;
  };

  return { tree: rewritten, config: config as DialConfig, css, vars, ground, dark: isDark(ground), fonts: [...families], texts, hasPress };
}

function fontValue(token: PaperToken) {
  return token.type === "fontFamily" && !/["',]/.test(token.value) ? `"${token.value}"` : token.value;
}
