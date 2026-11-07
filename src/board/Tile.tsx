import { memo, useEffect, useLayoutEffect, useRef, useState, type CSSProperties } from "react";
import type { StageMessage } from "../stage/protocol";
import { developOn } from "./develop";
import { cropOf, type Item } from "./items";
import { CARD_W, type Instance } from "./layout";

/**
 * Starting an iframe costs a frame or two, so a burst of new cards takes turns. Until its turn comes
 * a card shows its plate, developing as you arrive.
 */
const STARTS: (() => void)[] = [];
let starting = false;

function takeTurn(start: () => void) {
  STARTS.push(start);
  if (!starting) {
    starting = true;
    const next = () => {
      const run = STARTS.shift();
      if (!run) {
        starting = false;
        return;
      }
      run();
      setTimeout(next, 70);
    };
    setTimeout(next, 0);
  }
  return () => {
    const at = STARTS.indexOf(start);
    if (at >= 0) STARTS.splice(at, 1);
  };
}

const calm = () => matchMedia("(prefers-reduced-motion: reduce)").matches;

export type TileCallbacks = {
  onOpen: (key: string) => void;
  onDriving: (key: string) => void;
  onEscape: () => void;
};

type Props = TileCallbacks & {
  instance: Instance;
  item: Item;
  running: boolean;
  /** The card's transform while it stands in the detail view; null on the wall. */
  raised: { x: number; y: number; k: number } | null;
  /** Flying home after the detail view closed, still above the scrim until it lands. */
  landing: boolean;
  covered: boolean;
  /** Goes up each time the loop should start again from the top. */
  replay: number;
};

function Frame({ item, raised, onMessage, frame }: { item: Extract<Item, { kind: "demo" }>; raised: boolean; onMessage: (message: StageMessage) => void; frame: React.RefObject<HTMLIFrameElement | null> }) {
  const crop = cropOf(item.demo);
  const scale = CARD_W / crop.w;
  const handler = useRef(onMessage);
  handler.current = onMessage;

  useEffect(() => {
    const listen = (event: MessageEvent<StageMessage>) => {
      if (event.source === frame.current?.contentWindow) handler.current(event.data);
    };
    addEventListener("message", listen);
    return () => removeEventListener("message", listen);
  }, [frame]);

  return (
    <iframe
      ref={frame}
      className="tile-frame"
      title={`${item.title}, running`}
      src={`${import.meta.env.BASE_URL}stage.html?demo=${encodeURIComponent(item.id)}`}
      tabIndex={raised ? 0 : -1}
      style={{ width: item.demo.viewport.w, height: item.demo.viewport.h, transform: `scale(${scale}) translate(${-crop.x}px, ${-crop.y}px)` }}
    />
  );
}

function Media({ item, onReady }: { item: Extract<Item, { kind: "material" }>; onReady: () => void }) {
  const src = `${import.meta.env.BASE_URL}${item.material.src}`;
  if (item.material.kind === "video") return <video className="tile-media" src={src} muted loop autoPlay playsInline onLoadedData={onReady} onError={onReady} />;
  return <img className="tile-media" src={src} alt={item.title} draggable={false} onLoad={onReady} onError={onReady} />;
}

export const Tile = memo(function Tile({ instance, item, running, raised, landing, covered, replay, onOpen, onDriving, onEscape }: Props) {
  const [started, setStarted] = useState(item.kind === "material");
  const [ready, setReady] = useState(false);
  const [settled, setSettled] = useState(false);
  const [failed, setFailed] = useState<string | null>(null);
  const plate = useRef<HTMLCanvasElement>(null);
  const develop = useRef<ReturnType<typeof developOn> | null>(null);
  const frame = useRef<HTMLIFrameElement | null>(null);
  const bare = item.kind === "material" && item.material.bare;

  useEffect(() => {
    if (!started) return takeTurn(() => setStarted(true));
  }, [started]);

  useLayoutEffect(() => {
    const canvas = plate.current;
    if (!canvas || calm() || bare) return;
    develop.current = developOn(canvas, { ground: item.ground, dark: item.dark });
    return () => develop.current?.cancel();
  }, [item.ground, item.dark, bare]);

  useEffect(() => {
    if (!ready) return;
    if (develop.current) develop.current.reveal(() => setSettled(true));
    else setSettled(true);
  }, [ready]);

  useEffect(() => {
    if (!ready) return;
    frame.current?.contentWindow?.postMessage({ type: "run", run: running }, location.origin);
    const video = plate.current?.parentElement?.querySelector("video");
    if (video) void (running ? video.play().catch(() => {}) : video.pause());
  }, [running, ready]);

  useEffect(() => {
    if (replay > 0) frame.current?.contentWindow?.postMessage({ type: "replay" }, location.origin);
  }, [replay]);

  const style: CSSProperties = {
    width: instance.w,
    height: instance.h,
    transform: raised ? `translate3d(${raised.x}px, ${raised.y}px, 0) scale(${raised.k})` : `translate3d(${instance.x}px, ${instance.y}px, 0)`,
  };

  return (
    <figure className="tile" style={style} inert={covered} data-raised={raised ? "" : undefined} data-landing={landing ? "" : undefined} data-bare={bare ? "" : undefined} data-key={instance.key}>
      <div className="tile-body" style={bare ? undefined : { background: item.ground }}>
        {item.kind === "demo" && started ? (
          <Frame
            item={item}
            raised={Boolean(raised)}
            frame={frame}
            onMessage={(message) => {
              if (message.type === "ready") setReady(true);
              if (message.type === "driving") onDriving(instance.key);
              if (message.type === "escape") onEscape();
              if (message.type === "failed") {
                setFailed(message.message);
                setReady(true);
              }
            }}
          />
        ) : null}
        {item.kind === "material" ? <Media item={item} onReady={() => setReady(true)} /> : null}
        {failed ? <p className="tile-failed">{item.title} didn’t load. {failed}</p> : null}
        {settled || bare ? null : <canvas ref={plate} className="tile-plate" aria-hidden="true" />}
      </div>
      <button type="button" className="tile-hit" aria-label={`Open ${item.title}${item.project === "material" ? "" : `, ${item.project}`}`} onClick={() => onOpen(instance.key)} />
      <figcaption className="tile-caption">
        {item.title}
        {item.project === "material" ? null : <span> · {item.project}</span>}
      </figcaption>
    </figure>
  );
});
