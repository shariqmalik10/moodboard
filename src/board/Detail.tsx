import { DialRoot, useDialKitController, type DialConfig } from "dialkit";
import "dialkit/styles.css";
import { useEffect, useMemo, useRef } from "react";
import type { Demo } from "../demos/types";
import { tuneChannel } from "../demos/tune";
import { cropOf, type Item } from "./items";
import { CloseIcon } from "./icons";
import { CAN_EDIT } from "./useBoard";
import "./dial-store";

const PANEL_W = 360;

export type Rect = { x: number; y: number; w: number; h: number };

/** Where the card stands while open: as big as fits beside the panel, up to 1.6 times its real size. */
export function detailRect(item: Item, vw: number, vh: number): Rect {
  const wide = vw >= 900;
  const pad = wide ? 40 : 16;
  const areaW = vw - pad * 2 - (wide ? PANEL_W : 0);
  const areaH = (wide ? vh : vh * 0.42) - pad * 2;
  const natural = item.kind === "demo" ? cropOf(item.demo).w * 1.6 : item.material.w;
  const w = Math.min(areaW, areaH / item.aspect, natural);
  const h = w * item.aspect;
  return { x: pad + (areaW - w) / 2, y: pad + (areaH - h) / 2, w, h };
}

type Props = {
  item: Item;
  closing: boolean;
  onClose: () => void;
  onReplay: () => void;
  onRemove: () => void;
};

/** The panel for one component. Its values reach every live copy of that component on the wall. */
function DemoDials({ demo, onReplay }: { demo: Demo; onReplay: () => void }) {
  const config = useMemo(() => ({ ...demo.dials.config, replay: { type: "action", label: "Replay the loop" }, reset: { type: "action", label: "Reset every dial" } }) as DialConfig, [demo]);
  const dial = useDialKitController(demo.title, config, {
    id: demo.id,
    persist: true,
    onAction: (path) => {
      if (path === "replay") onReplay();
      if (path === "reset") dial.resetValues();
    },
  });
  const channel = useRef<BroadcastChannel | null>(null);
  useEffect(() => {
    channel.current = new BroadcastChannel(tuneChannel(demo.id));
    return () => channel.current?.close();
  }, [demo.id]);
  useEffect(() => {
    channel.current?.postMessage(dial.values);
  }, [dial.values]);
  return <DialRoot mode="inline" theme="system" productionEnabled versions="menu" />;
}

export function Detail({ item, closing, onClose, onReplay, onRemove }: Props) {
  const close = useRef<HTMLButtonElement>(null);
  useEffect(() => close.current?.focus({ preventScroll: true }), []);

  return (
    <aside className="detail" role="dialog" aria-modal="true" aria-label={item.title} data-closing={closing ? "" : undefined}>
      <div className="detail-bar">
        {CAN_EDIT ? (
          <button type="button" className="text-button text-button-quiet" onClick={onRemove}>
            Take off the wall
          </button>
        ) : null}
        <button ref={close} type="button" className="icon-button detail-close" aria-label="Close" onClick={onClose}>
          <CloseIcon />
        </button>
      </div>
      {item.kind === "demo" ? (
        <div className="detail-dials">
          <DemoDials demo={item.demo} onReplay={onReplay} />
        </div>
      ) : (
        <h2 className="detail-title">{item.title}</h2>
      )}
    </aside>
  );
}
