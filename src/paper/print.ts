import type { PaperNode, PaperValue } from "./parse";

type Printing = {
  value?: (value: PaperValue) => PaperValue;
  text?: (text: string) => string;
};

const IDENTIFIER = /^[A-Za-z_$][\w$]*$/;

const literal = (value: PaperValue) => (typeof value === "number" ? String(value) : JSON.stringify(value));

function printStyle(style: Record<string, PaperValue>, value: NonNullable<Printing["value"]>) {
  const parts = Object.entries(style).map(([key, each]) => `${IDENTIFIER.test(key) ? key : JSON.stringify(key)}: ${literal(value(each))}`);
  return `style={{ ${parts.join(", ")} }}`;
}

function printAttr(key: string, value: PaperValue) {
  return typeof value === "number" ? `${key}={${value}}` : `${key}=${JSON.stringify(value)}`;
}

/** Text that JSX would change or read as code goes in an expression, so it comes back exactly as written. */
function printText(text: string) {
  return /^\S(.*\S)?$/.test(text) && !/[{}<>&]/.test(text) ? text : `{${JSON.stringify(text)}}`;
}

/** Writes a design back out as JSX that `parseJsx` reads to the same tree. */
export function printJsx(node: PaperNode, printing: Printing = {}, depth = 0): string {
  const value = printing.value ?? ((each: PaperValue) => each);
  const text = printing.text ?? ((each: string) => each);
  const pad = "  ".repeat(depth);
  const attrs = Object.entries(node.attrs).map(([key, each]) => printAttr(key, value(each)));
  if (Object.keys(node.style).length > 0) attrs.push(printStyle(node.style, value));
  const open = [node.tag, ...attrs].join(" ");
  if (node.children.length === 0) return `${pad}<${open} />`;
  const children = node.children.map((child) => (typeof child === "string" ? `${pad}  ${printText(text(child))}` : printJsx(child, printing, depth + 1)));
  return `${pad}<${open}>\n${children.join("\n")}\n${pad}</${node.tag}>`;
}
