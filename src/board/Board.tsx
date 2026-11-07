import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { flushSync } from "react-dom";
import type { Placement } from "./board-model";
import { Camera } from "./camera";
import { Detail, detailRect } from "./Detail";
import { Dock, type Filter } from "./Dock";
import { heightOf } from "./items";
import { buildLayout, CARD_W, cardsIn, GAP, slotAt, type Instance } from "./layout";
import { Tile } from "./Tile";
import { addMaterial, CAN_EDIT, placeOnWall, removeFromWall, useBoard } from "./useBoard";

/** How many cards may stand mounted at once; past this the nearest to the centre win. */
const MAX_MOUNTED = 30;
const MOUNT_MARGIN = 320;
const SLOT_ID = "__slot";
const SLOT_H = 260;
const LAND_MS = 440;
const HINT_KEY = "moodboard:hint-seen";

type Open = { key: string; closing: boolean; driving: boolean };
type Seen = { cards: Instance[]; running: Set<string>; signature: string };

const homeCamera = () => {
  const vw = innerWidth;
  const z = vw >= 1500 ? 1 : vw >= 1000 ? 0.86 : 0.62;
  return { x: GAP * 1.5, y: GAP * 1.5, z };
};

export function Board() {
  const { columns, items, offWall } = useBoard();
  const [camera] = useState(() => new Camera());
  const wall = useRef<HTMLDivElement>(null);
  const world = useRef<HTMLDivElement>(null);

  const [filter, setFilter] = useState<Filter>("all");
  const [slot, setSlot] = useState<Placement | null>(null);
  const [open, setOpen] = useState<Open | null>(null);
  const [replays, setReplays] = useState<Record<string, number>>({});
  const [zoom, setZoom] = useState(() => homeCamera().z);
  const [message, setMessage] = useState<string | null>(null);
  const [hint, setHint] = useState(() => {
    try {
      return !localStorage.getItem(HINT_KEY);
    } catch {
      return true;
    }
  });
  const [seen, setSeen] = useState<Seen>({ cards: [], running: new Set(), signature: "" });

  const shown = useMemo(
    () => columns.map((list) => list.filter((id) => items.has(id) && (filter === "all" || items.get(id)?.project === filter))),
    [columns, items, filter],
  );
  const base = useMemo(() => buildLayout(shown, (id) => heightOf(items.get(id))), [shown, items]);
  const layout = useMemo(() => {
    if (!slot) return base;
    const withSlot = shown.map((list, at) => (at === slot.column ? [...list.slice(0, slot.index), SLOT_ID, ...list.slice(slot.index)] : list));
    return buildLayout(withSlot, (id) => (id === SLOT_ID ? SLOT_H : heightOf(items.get(id))));
  }, [base, shown, slot, items]);

  const measure = useCallback(() => {
    const { x, y, z } = camera.cam;
    const screen = { x0: -x / z, y0: -y / z, x1: (innerWidth - x) / z, y1: (innerHeight - y) / z };
    const margin = MOUNT_MARGIN / z;
    const around = { x0: screen.x0 - margin, y0: screen.y0 - margin, x1: screen.x1 + margin, y1: screen.y1 + margin };
    const middleX = (screen.x0 + screen.x1) / 2;
    const middleY = (screen.y0 + screen.y1) / 2;
    const reach = (card: Instance) => Math.hypot(card.x + card.w / 2 - middleX, card.y + card.h / 2 - middleY);
    const cards = cardsIn(layout, around)
      .sort((a, b) => reach(a) - reach(b))
      .slice(0, MAX_MOUNTED)
      .sort((a, b) => (a.key < b.key ? -1 : 1));
    const running = new Set(cards.filter((card) => card.x < screen.x1 && card.x + card.w > screen.x0 && card.y < screen.y1 && card.y + card.h > screen.y0).map((card) => card.key));
    const signature = `${cards.map((card) => `${card.key}@${card.x},${card.y}`).join(" ")}/${[...running].join(" ")}`;
    setSeen((previous) => (previous.signature === signature ? previous : { cards, running, signature }));
  }, [camera, layout]);

  useLayoutEffect(() => {
    if (world.current) camera.bind(world.current);
    if (camera.cam.x === 0 && camera.cam.y === 0) camera.set(homeCamera());
  }, [camera]);

  useEffect(() => {
    measure();
    let queued = 0;
    let lastZoom = camera.cam.z;
    const stop = camera.subscribe(() => {
      const { z } = camera.cam;
      if (z !== lastZoom) {
        lastZoom = z;
        setZoom(z);
      }
      if (!queued) {
        queued = requestAnimationFrame(() => {
          queued = 0;
          measure();
        });
      }
    });
    addEventListener("resize", measure);
    return () => {
      stop();
      cancelAnimationFrame(queued);
      removeEventListener("resize", measure);
    };
  }, [camera, measure]);

  useEffect(() => (wall.current ? camera.attach(wall.current) : undefined), [camera]);

  const dismissHint = useCallback(() => {
    setHint(false);
    try {
      localStorage.setItem(HINT_KEY, "1");
    } catch {}
  }, []);

  useEffect(() => {
    if (!hint) return;
    const start = camera.cam;
    return camera.subscribe(() => {
      if (Math.hypot(camera.cam.x - start.x, camera.cam.y - start.y) > 80) dismissHint();
    });
  }, [camera, hint, dismissHint]);

  /** A new card that lands out of sight gets brought into view, wherever it came from. */
  const known = useRef<Set<string> | null>(null);
  useEffect(() => {
    const ids = new Set(columns.flat());
    const previous = known.current;
    known.current = ids;
    if (!previous || open) return;
    const fresh = [...ids].filter((id) => !previous.has(id)).at(-1);
    if (!fresh) return;
    const { x, y, z } = camera.cam;
    const screen = { x0: -x / z, y0: -y / z, x1: (innerWidth - x) / z, y1: (innerHeight - y) / z };
    if (cardsIn(base, screen).some((card) => card.id === fresh)) return;
    const range = 6000;
    const middleX = (screen.x0 + screen.x1) / 2;
    const middleY = (screen.y0 + screen.y1) / 2;
    const target = cardsIn(base, { x0: middleX - range, y0: middleY - range, x1: middleX + range, y1: middleY + range })
      .filter((card) => card.id === fresh)
      .sort((a, b) => Math.hypot(a.x - middleX, a.y - middleY) - Math.hypot(b.x - middleX, b.y - middleY))[0];
    if (target) camera.easeTo({ x: innerWidth / 2 - (target.x + target.w / 2) * z, y: innerHeight / 2 - (target.y + target.h / 2) * z });
  }, [columns, base, camera, open]);

  const openCard = useCallback(
    (key: string) => {
      if (camera.dragged) {
        camera.dragged = false;
        return;
      }
      dismissHint();
      camera.locked = true;
      setOpen({ key, closing: false, driving: false });
    },
    [camera, dismissHint],
  );

  const closeCard = useCallback(() => {
    setOpen((current) => {
      if (!current || current.closing) return current;
      if (current.driving) setReplays((all) => ({ ...all, [current.key]: (all[current.key] ?? 0) + 1 }));
      return { ...current, closing: true };
    });
  }, []);

  useEffect(() => {
    if (!open?.closing) return;
    const key = open.key;
    const timer = setTimeout(() => {
      // Synchronous, because the wall can't take focus until it has stopped being inert.
      flushSync(() => setOpen(null));
      camera.locked = false;
      wall.current?.querySelector<HTMLElement>(`[data-key="${CSS.escape(key)}"] .tile-hit`)?.focus({ preventScroll: true });
    }, LAND_MS);
    return () => clearTimeout(timer);
  }, [open, camera]);

  const onDriving = useCallback((key: string) => setOpen((current) => (current?.key === key ? { ...current, driving: true } : current)), []);

  const replayOpen = useCallback(() => {
    setOpen((current) => {
      if (current) setReplays((all) => ({ ...all, [current.key]: (all[current.key] ?? 0) + 1 }));
      return current ? { ...current, driving: false } : current;
    });
  }, []);

  // Cards call focus() as they play, which would pull the page's keyboard into their iframes.
  const openRef = useRef(open);
  openRef.current = open;
  useEffect(() => {
    let last: HTMLElement | null = null;
    const remember = (event: FocusEvent) => {
      if (event.target instanceof HTMLElement && !(event.target instanceof HTMLIFrameElement)) last = event.target;
    };
    const reclaim = () => {
      setTimeout(() => {
        if (!(document.activeElement instanceof HTMLIFrameElement) || openRef.current?.driving) return;
        window.focus();
        if (last?.isConnected) last.focus({ preventScroll: true });
      }, 0);
    };
    addEventListener("focusin", remember);
    addEventListener("blur", reclaim);
    return () => {
      removeEventListener("focusin", remember);
      removeEventListener("blur", reclaim);
    };
  }, []);

  const panTo = useCallback(
    (dx: number, dy: number) => {
      camera.easeTo({ x: camera.cam.x + dx, y: camera.cam.y + dy }, 280);
    },
    [camera],
  );

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape" && openRef.current) {
        closeCard();
        return;
      }
      if (openRef.current || (event.target as Element)?.closest?.("input, textarea, #add-panel")) return;
      const moves: Record<string, [number, number]> = { ArrowLeft: [260, 0], ArrowRight: [-260, 0], ArrowUp: [0, 260], ArrowDown: [0, -260] };
      if (moves[event.key]) {
        event.preventDefault();
        panTo(...moves[event.key]);
      } else if (event.key === "+" || event.key === "=") camera.zoomAt(innerWidth / 2, innerHeight / 2, 1.2);
      else if (event.key === "-") camera.zoomAt(innerWidth / 2, innerHeight / 2, 1 / 1.2);
      else if (event.key === "0") camera.easeTo(homeCamera());
    };
    addEventListener("keydown", onKey);
    return () => removeEventListener("keydown", onKey);
  }, [camera, closeCard, panTo]);

  const slotUnder = useCallback(
    (screenX: number, screenY: number) => {
      const { x, y, z } = camera.cam;
      return slotAt(base, (screenX - x) / z, (screenY - y) / z);
    },
    [base, camera],
  );

  const addFiles = useCallback(async (files: File[], at?: Placement) => {
    setFilter("all");
    try {
      for (const [offset, file] of files.entries()) await addMaterial(file, at ? { column: at.column, index: at.index + offset } : undefined);
    } catch (reason) {
      setMessage(reason instanceof Error ? reason.message : "That file couldn’t be added.");
      setTimeout(() => setMessage(null), 4000);
    }
  }, []);

  useEffect(() => {
    if (!CAN_EDIT) return;
    const carriesFiles = (event: DragEvent) => event.dataTransfer?.types.includes("Files");
    const onOver = (event: DragEvent) => {
      if (!carriesFiles(event) || openRef.current) return;
      event.preventDefault();
      setFilter("all");
      const next = slotUnder(event.clientX, event.clientY);
      setSlot((current) => (current?.column === next.column && current.index === next.index ? current : next));
    };
    const onLeave = (event: DragEvent) => {
      if (!event.relatedTarget) setSlot(null);
    };
    const onDrop = (event: DragEvent) => {
      if (!carriesFiles(event)) return;
      event.preventDefault();
      const files = Array.from(event.dataTransfer?.files ?? []);
      const at = slotUnder(event.clientX, event.clientY);
      setSlot(null);
      void addFiles(files, at);
    };
    const onPaste = (event: ClipboardEvent) => {
      const files = Array.from(event.clipboardData?.files ?? []);
      if (files.length) void addFiles(files, slotUnder(innerWidth / 2, innerHeight / 2));
    };
    addEventListener("dragover", onOver);
    addEventListener("dragleave", onLeave);
    addEventListener("drop", onDrop);
    addEventListener("paste", onPaste);
    return () => {
      removeEventListener("dragover", onOver);
      removeEventListener("dragleave", onLeave);
      removeEventListener("drop", onDrop);
      removeEventListener("paste", onPaste);
    };
  }, [addFiles, slotUnder]);

  const onWallFocus = useCallback(
    (event: React.FocusEvent) => {
      const target = event.target as HTMLElement;
      if (!target.matches(":focus-visible") || !target.classList.contains("tile-hit")) return;
      const box = target.getBoundingClientRect();
      const inset = 32;
      const dx = box.left < inset ? inset - box.left : box.right > innerWidth - inset ? innerWidth - inset - box.right : 0;
      const dy = box.top < inset ? inset - box.top : box.bottom > innerHeight - 96 ? innerHeight - 96 - box.bottom : 0;
      if (dx || dy) panTo(dx, dy);
    },
    [panTo],
  );

  const demosShown = useMemo(() => new Set(shown.flat().filter((id) => items.get(id)?.kind === "demo")).size, [shown, items]);
  const openCardInstance = open ? seen.cards.find((card) => card.key === open.key) : undefined;
  const openItem = openCardInstance ? items.get(openCardInstance.id) : undefined;
  const openRect = openItem ? detailRect(openItem, innerWidth, innerHeight) : null;
  const { x: camX, y: camY, z: camZ } = camera.cam;

  return (
    <>
      <div ref={wall} className="wall" data-open={open ? "" : undefined} onFocus={onWallFocus}>
        <div ref={world} className="world">
          {open ? <div className="scrim" data-closing={open.closing ? "" : undefined} style={{ left: -camX / camZ - 40, top: -camY / camZ - 40, width: innerWidth / camZ + 80, height: innerHeight / camZ + 80 }} /> : null}
          {seen.cards.map((card) => {
            if (card.id === SLOT_ID) return <div key={card.key} className="tile-slot" style={{ width: card.w, height: card.h, transform: `translate3d(${card.x}px, ${card.y}px, 0)` }} />;
            const item = items.get(card.id);
            if (!item) return null;
            const isOpen = open?.key === card.key;
            const standing = isOpen && !open.closing && openRect;
            return (
              <Tile
                key={card.key}
                instance={card}
                item={item}
                running={open ? isOpen : seen.running.has(card.key)}
                raised={standing ? { x: (openRect.x - camX) / camZ, y: (openRect.y - camY) / camZ, k: openRect.w / (CARD_W * camZ) } : null}
                landing={isOpen && open.closing}
                covered={Boolean(open) && !isOpen}
                replay={replays[card.key] ?? 0}
                onOpen={openCard}
                onDriving={onDriving}
                onEscape={closeCard}
              />
            );
          })}
        </div>
      </div>

      <header className="masthead" inert={Boolean(open)}>
        <h1>Components, in motion</h1>
        <p>
          {demosShown} components
        </p>
      </header>

      {hint ? <p className="hint">Scroll any way you like. Press a card to open it.</p> : null}

      <Dock
        filter={filter}
        zoom={zoom}
        offWall={offWall}
        message={message}
        inert={Boolean(open)}
        onFilter={setFilter}
        onZoom={(factor) => camera.zoomAt(innerWidth / 2, innerHeight / 2, factor)}
        onHome={() => camera.easeTo(homeCamera())}
        onFiles={(files) => void addFiles(files, slotUnder(innerWidth / 2, innerHeight / 2))}
        onPlace={(id) => {
          setFilter("all");
          void placeOnWall(id, slotUnder(innerWidth / 2, innerHeight / 2));
        }}
      />

      {open && openItem ? (
        <Detail
          item={openItem}
          closing={open.closing}
          onClose={closeCard}
          onReplay={replayOpen}
          onRemove={() => {
            void removeFromWall(openItem.id);
            setOpen(null);
            camera.locked = false;
          }}
        />
      ) : null}
    </>
  );
}
