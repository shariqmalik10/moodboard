import { createElement, type ReactNode } from "react";
import type { Demo, Script } from "../demos/types";
import { useTuned } from "../stage/tuned";
import { derive, type PaperRecord } from "./derive";
import { parseJsx, type PaperNode } from "./parse";

/** A family that isn't installed comes from Google Fonts, trying its full weight range first. */
function loadFonts(families: string[]) {
  for (const family of families) {
    if (document.querySelector(`link[data-family="${family}"]`)) continue;
    const name = family.replace(/ /g, "+");
    const link = Object.assign(document.createElement("link"), { rel: "stylesheet", href: `https://fonts.googleapis.com/css2?family=${name}:wght@100..900&display=swap` });
    link.dataset.family = family;
    link.onerror = () => {
      link.onerror = null;
      link.href = `https://fonts.googleapis.com/css2?family=${name}&display=swap`;
    };
    document.head.append(link);
  }
}

function render(node: PaperNode, texts: Map<string, string>, key?: number, order?: number): ReactNode {
  const style = order === undefined ? node.style : { ...node.style, "--paper-i": order };
  const props: Record<string, unknown> = { ...node.attrs, style, key };
  const children = node.children.map((child, at) => (typeof child === "string" ? (texts.get(child) ?? child) : render(child, texts, at, key === undefined ? at : undefined)));
  return createElement(node.tag, props, ...children);
}

export function paperDemo(record: PaperRecord): Demo {
  const derived = derive(parseJsx(record.jsx), record.tokens);
  const script: Script = derived.hasPress
    ? [{ wait: 1100 }, { hover: ".paper-press" }, { wait: 500 }, { click: ".paper-press", hold: 160 }, { wait: 700 }, { leave: true }]
    : [{ wait: 3400 }];

  function Component() {
    const tuned = useTuned<never>() as { Text?: Record<string, string> };
    const texts = new Map<string, string>();
    const words = Object.values(tuned?.Text ?? {});
    derived.texts.forEach((text, at) => {
      if (words[at] !== undefined) texts.set(text, words[at]);
    });
    const top = render(derived.tree, texts) as ReactNode;
    return <div className="paper-root" style={{ width: record.viewport.w, height: record.viewport.h, position: "relative", overflow: "hidden" }}>{top}</div>;
  }

  loadFonts(derived.fonts);
  document.documentElement.style.setProperty("--stage-ground", derived.ground);

  return {
    id: record.id,
    project: "paper",
    title: record.title,
    viewport: record.viewport,
    dark: derived.dark,
    ground: derived.ground,
    cursor: derived.hasPress ? "arrow" : "none",
    script,
    dials: { config: derived.config, css: derived.css },
    load: async () => ({ default: Component }),
  };
}
