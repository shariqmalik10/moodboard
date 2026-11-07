import { Fragment, type ComponentType } from "react";
import { createRoot } from "react-dom/client";
import { resolveDemo } from "../demos/resolve";
import { resolveValues, tuneChannel, tuneKey } from "../demos/tune";
import { Director } from "./director";
import { inApp, onHost, savedByApp, tell } from "./host";
import { teachSheet, watchPseudoStates } from "./pseudo";
import { readStructure, type Crop } from "./structure";
import { setTuned } from "./tuned";
import "./stage.css";

/** Cards share an origin, so each gets its own storage: one collapsed rail must not collapse another. */
function isolateStorage() {
  const items = new Map<string, string>();
  const storage: Storage = {
    get length() {
      return items.size;
    },
    clear: () => items.clear(),
    getItem: (key) => items.get(key) ?? null,
    key: (index) => [...items.keys()][index] ?? null,
    removeItem: (key) => void items.delete(key),
    setItem: (key, value) => void items.set(key, String(value)),
  };
  Object.defineProperty(window, "localStorage", { value: storage, configurable: true });
}

const pause = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));
// A covered window gets no animation frames, and an import often arrives while the window is covered.
const frame = () => Promise.race([new Promise<void>((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve()))), pause(120)]);

/** What the panel last saved for this component, from the real storage the card is about to leave. */
async function savedDials(id: string): Promise<Record<string, unknown> | undefined> {
  if (inApp) return (await savedByApp(id))?.values;
  try {
    return JSON.parse(localStorage.getItem(tuneKey(id)) ?? "null")?.values;
  } catch {
    return undefined;
  }
}

function setNight(night: boolean) {
  const root = document.documentElement;
  if (night) root.dataset.dark = "";
  else delete root.dataset.dark;
  root.dataset.kTheme = night ? "night" : "paper";
}

/** Any colour the browser understands, as the hex the app reads. */
function hexOf(colour: string) {
  const context = document.createElement("canvas").getContext("2d", { willReadFrequently: true });
  if (!context) return "#ffffff";
  context.fillStyle = colour;
  context.fillRect(0, 0, 1, 1);
  return `#${[...context.getImageData(0, 0, 1, 1).data.slice(0, 3)].map((channel) => channel.toString(16).padStart(2, "0")).join("")}`;
}

/** How much room a component wants, and what it sits on, for one that came with no size of its own. */
function measureContent(host: HTMLElement) {
  const portalled = [...document.body.children].filter((each) => each !== host && !["SCRIPT", "STYLE", "NOSCRIPT"].includes(each.tagName) && !each.classList.contains("stage-cursor"));
  const boxes = [...host.children, ...portalled].map((each) => each.getBoundingClientRect()).filter((box) => box.width > 0 && box.height > 0);
  const tiny = boxes.every((box) => box.width < 36 && box.height < 36);
  const width = boxes.length > 0 ? Math.max(...boxes.map((box) => box.right)) - Math.min(...boxes.map((box) => box.left)) : 0;
  const height = boxes.length > 0 ? Math.max(...boxes.map((box) => box.bottom)) - Math.min(...boxes.map((box) => box.top)) : 0;
  const isClear = (colour: string) => colour === "transparent" || /rgba\(0, 0, 0, 0\)/.test(colour);
  const fromBody = getComputedStyle(document.body).backgroundColor;
  const fromPage = getComputedStyle(document.documentElement).backgroundColor;
  return { width, height, ground: hexOf(isClear(fromBody) ? (isClear(fromPage) ? "#ffffff" : fromPage) : fromBody), blank: boxes.length === 0 || tiny };
}

async function boot() {
  const params = new URLSearchParams(location.search);
  // A generated entrance waits until the component is really on show, so its first frame always matches the plate.
  if (params.has("still") || params.has("held")) document.documentElement.dataset.still = "";
  const demo = await resolveDemo(params.get("demo") ?? "");
  const saved = await savedDials(demo.id);
  isolateStorage();
  setNight(Boolean(demo.dark));

  const { default: Component } = (await demo.load()) as { default: ComponentType };
  watchPseudoStates();

  // Added after the component's own CSS, so a dial wins over the rule it retunes.
  const sheet = document.head.appendChild(Object.assign(document.createElement("style"), { id: "dials" }));
  const tune = (values: Record<string, unknown>) => {
    sheet.textContent = demo.dials.css(values);
    teachSheet(sheet.sheet);
    setNight(Boolean((values.Theme as { night?: boolean } | undefined)?.night ?? demo.dark));
    setTuned(values);
  };
  tune(resolveValues(demo.dials.config, saved));
  if (!inApp) new BroadcastChannel(tuneChannel(demo.id)).onmessage = (event: MessageEvent<Record<string, unknown>>) => tune(event.data);

  const host = document.getElementById("stage") as HTMLElement;
  // A component from a project can throw for want of data, and the app needs to hear why instead of waiting.
  const isFromProject = document.documentElement.hasAttribute("data-project");
  const root = createRoot(host, isFromProject ? { onUncaughtError: (error) => tell({ type: "failed", id: demo.id, message: error instanceof Error ? error.message : String(error) }) } : {});
  let run = 0;
  const mount = () => root.render(<Fragment key={run}><Component /></Fragment>);
  const remount = () => {
    delete document.documentElement.dataset.still;
    run += 1;
    localStorage.clear();
    mount();
  };

  const director = new Director(demo.script, demo.cursor, async () => {
    host.style.opacity = "0";
    await pause(180);
    remount();
    await frame();
    host.style.opacity = "1";
  });

  if (params.has("measure")) document.documentElement.dataset.measuring = "";
  mount();
  await Promise.race([document.fonts.ready, pause(600)]);
  await frame();
  demo.afterMount?.();
  if (params.has("measure")) {
    await pause(120);
    tell({ type: "measured", id: demo.id, ...measureContent(host) });
    return;
  }
  if (params.has("still")) {
    document.documentElement.dataset.still = "";
    // A plate taken before the art arrives keeps its placeholder until the tune changes, and a page nobody can see never starts a lazy image.
    const images = [...document.images];
    for (const image of images) image.loading = "eager";
    await Promise.race([Promise.allSettled(images.map((image) => image.decode())), pause(3000)]);
  }

  // `still` holds the component at rest, for the plate the app forms a tile from. `held` waits to be told to run.
  const calm = matchMedia("(prefers-reduced-motion: reduce)").matches;
  const shownFirst = params.has("still") || params.has("held");
  if (params.has("held")) director.setPaused(true);
  if (shownFirst && demo.pose) await director.pose(demo.pose);
  if (!calm && !params.has("still")) director.start(shownFirst ? demo.pose : 0);
  (window as unknown as { __structure: (crop: Crop) => unknown }).__structure = readStructure;
  tell({ type: "ready", id: demo.id });

  const startOver = async () => {
    director.stop();
    remount();
    await frame();
    if (!demo.pose) return;
    await director.pose(demo.pose);
    director.stop();
  };

  onHost((message) => {
    if (message.type === "run") director.setPaused(!message.run);
    if (message.type === "tune") tune(resolveValues(demo.dials.config, message.saved));
    if (message.type === "replay") {
      remount();
      director.setPaused(false);
      director.start();
    }
    if (message.type === "drive") director.stop();
    if (message.type === "reset") void startOver();
    if (message.type === "watch") {
      remount();
      director.setPaused(false);
      director.start(0, true);
    }
  });

  // A person's own pointer on the card ends the scripted loop, and the component is simply theirs.
  const takeOver = (event: Event) => {
    if (!event.isTrusted) return;
    director.stop();
    tell({ type: "driving", id: demo.id });
  };
  addEventListener("pointerdown", takeOver, true);
  addEventListener("pointermove", takeOver, true);
  addEventListener("keydown", (event) => {
    // Esc belongs to the component while it has a dialog open, and to the wall otherwise.
    if (event.isTrusted && event.key === "Escape" && !document.querySelector("dialog[open]")) tell({ type: "escape", id: demo.id });
    else takeOver(event);
  }, true);
}

boot().catch((reason: unknown) => {
  console.error(reason);
  const id = new URLSearchParams(location.search).get("demo") ?? "";
  tell({ type: "failed", id, message: reason instanceof Error ? reason.message : String(reason) });
});
