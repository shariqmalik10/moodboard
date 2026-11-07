import "virtual:moodboard/globals";
import type { Demo, Script, Step } from "../../src/demos/types";

const INTERACTIVE = "button:enabled, a[href], [role='button'], [role='tab'], [role='switch'], input:not([type='hidden'], [type='checkbox'], [type='radio']), textarea, summary";

/** A generic loop: the pointer visits what can be used, so a component nobody scripted still shows its states. */
function tour(): Script {
  const targets = [...document.querySelectorAll<HTMLElement>(`#stage :is(${INTERACTIVE})`)].filter((each) => each.getBoundingClientRect().width > 0).slice(0, 4);
  if (targets.length === 0) return [{ wait: 3400 }];
  const script: Step[] = [{ wait: 900 }];
  const all = [...document.querySelectorAll<HTMLElement>(`#stage :is(${INTERACTIVE})`)];
  for (const target of targets) {
    const selector = { sel: `#stage :is(${INTERACTIVE})`, nth: all.indexOf(target) };
    if (target.matches("input, textarea")) script.push({ click: selector, hold: 80 }, { type: "Sample", cps: 8 }, { wait: 500 });
    else script.push({ hover: selector }, { wait: 450 }, { click: selector, hold: 120 }, { wait: 500 });
  }
  script.push({ leave: true }, { wait: 700 });
  return script;
}

export async function paperRecord() {
  return null;
}

export async function resolveDemo(id: string): Promise<Demo> {
  const response = await fetch(`/__moodboard/component?id=${encodeURIComponent(id)}`);
  if (!response.ok) throw new Error(`No component called ${id}`);
  const meta = (await response.json()) as { id: string; title: string; project: string; folder: string; props: Record<string, unknown> };
  const script: Script = [{ wait: 3400 }];
  return {
    id,
    project: meta.project as Demo["project"],
    title: meta.title,
    viewport: { w: innerWidth, h: innerHeight },
    ground: "",
    cursor: "arrow",
    script,
    dials: { config: Object.keys(meta.props).length > 0 ? ({ [meta.folder]: meta.props } as never) : {}, css: () => "" },
    afterMount() {
      script.splice(0, script.length, ...tour());
    },
    load: () => import(/* @vite-ignore */ `/@moodboard/component?id=${encodeURIComponent(id)}`),
  };
}
