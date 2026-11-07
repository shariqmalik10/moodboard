import board from "../board.json";
import { DEMOS } from "../demos/registry";
import { paperRecord, resolveDemo } from "../demos/resolve";
import { resolveValues } from "../demos/tune";
import { tuneSummary, writeBrief } from "../paper/brief";
import { derive, type PaperToken } from "../paper/derive";
import { parseJsx } from "../paper/parse";
import { tellNative } from "../stage/host";

const runtime = {
  catalog: () => ({
    board,
    demos: DEMOS.map(({ id, project, title, viewport, crop, dark, ground }) => ({ id, project, title, viewport, crop: crop ?? { x: 0, y: 0, ...viewport }, dark: Boolean(dark), ground })),
  }),
  /** What the app needs to know about a design before it can stand on the wall. Throws if it can't be read. */
  inspectPaper(jsx: string, tokens: PaperToken[]) {
    const derived = derive(parseJsx(jsx), tokens);
    return { ground: derived.ground, dark: derived.dark, fonts: derived.fonts, dials: Object.keys(derived.config) };
  },
  /** Everything Claude Code needs to build this component as the person tuned it. */
  async brief(id: string, saved?: Record<string, unknown>, note?: string) {
    return writeBrief(await resolveDemo(id), saved ?? {}, await paperRecord(id), note);
  },
  /** Which dials each component has moved. A component that can't be read any more is left out. */
  async tuneSummaries(saved: Record<string, Record<string, unknown>>) {
    const found = await Promise.all(Object.entries(saved).map(async ([id, values]) => {
      try {
        return [id, tuneSummary((await resolveDemo(id)).dials.config, values)] as const;
      } catch {
        return null;
      }
    }));
    return Object.fromEntries(found.filter((each) => each !== null));
  },
  async tuned(id: string, saved?: Record<string, unknown>) {
    const demo = await resolveDemo(id);
    const values = resolveValues(demo.dials.config, saved ?? {});
    return { config: demo.dials.config, values, css: demo.dials.css(values) };
  },
};

(window as unknown as { __runtime: typeof runtime }).__runtime = runtime;
tellNative({ type: "runtime-ready" });
