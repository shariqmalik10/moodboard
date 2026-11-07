import { DialRoot, DialStore, useDialKitController, type DialConfig, type DialValue } from "dialkit";
import "dialkit/styles.css";
import { useMemo } from "react";
import { createRoot } from "react-dom/client";
import "../board/dial-store";
import { resolveDemo } from "../demos/resolve";
import type { Demo } from "../demos/types";
import { tellNative } from "../stage/host";
import "./panel.css";

function Panel({ demo }: { demo: Demo }) {
  const config = useMemo(() => ({ ...demo.dials.config, reset: { type: "action", label: "Reset every dial" } }) as DialConfig, [demo]);
  const dial = useDialKitController(demo.title, config, {
    id: demo.id,
    persist: true,
    onAction: (path) => {
      if (path === "reset") dial.resetValues();
    },
  });
  return <DialRoot mode="inline" theme="system" productionEnabled versions="menu" />;
}

async function boot() {
  const id = new URLSearchParams(location.search).get("id") ?? "";
  const demo = await resolveDemo(id);
  const saved = await fetch(`api/dials?id=${encodeURIComponent(id)}`).then((response) => response.text());
  let stored: string | null = saved === "null" ? null : saved;

  // DialKit saves as it loads, and a saved value edits a project's source. Only a person's own hand may do that.
  let touched = false;
  const touch = (event: Event) => {
    if (event.isTrusted) touched = true;
  };
  addEventListener("pointerdown", touch, true);
  addEventListener("keydown", touch, true);

  // The app keeps the truth, so Claude Code can read a tune and restarts keep it.
  const storage = {
    getItem: () => stored,
    setItem: (_key: string, value: string) => {
      stored = value;
      tellNative({ type: "dials", id, state: JSON.parse(value), byPerson: touched });
    },
    removeItem: () => {
      stored = null;
      tellNative({ type: "dials", id, state: null, byPerson: touched });
    },
  };
  Object.defineProperty(window, "localStorage", { value: storage, configurable: true });

  (window as unknown as { __setDial: (path: string, value: DialValue) => void }).__setDial = (path, value) => DialStore.updateValue(id, path, value);
  createRoot(document.getElementById("panel") as HTMLElement).render(<Panel demo={demo} />);
}

boot().catch((reason: unknown) => {
  document.body.textContent = reason instanceof Error ? reason.message : String(reason);
});
