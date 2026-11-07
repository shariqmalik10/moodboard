"use client";

import { useEffect, useState } from "react";

type WateredToastProps = { plant?: string };

/** The note that slides up after watering, with a way to take it back. */
export function WateredToast({ plant = "Pothos" }: WateredToastProps) {
  const [shown, setShown] = useState(false);
  const [undone, setUndone] = useState(false);

  useEffect(() => {
    if (!shown) return;
    const hide = setTimeout(() => setShown(false), 4000);
    return () => clearTimeout(hide);
  }, [shown]);

  return (
    <div className="flex h-44 w-80 flex-col items-center justify-between">
      <button type="button" onClick={() => { setUndone(false); setShown(true); }} className="rounded-[12px] bg-leaf px-5 py-3 text-[14px] font-semibold text-white active:scale-[0.97] transition-transform">
        Water {plant}
      </button>
      <div role="status" className="flex w-full items-center justify-between rounded-[14px] bg-soil px-4 py-3 text-[14px] text-white transition-[opacity,transform] duration-300 ease-[cubic-bezier(0.2,0.8,0.2,1)]" style={{ opacity: shown ? 1 : 0, transform: shown ? "none" : "translateY(12px)" }}>
        <span>{undone ? `Took back watering ${plant}` : `${plant} watered`}</span>
        {!undone && <button type="button" onClick={() => setUndone(true)} className="font-semibold text-sprout">Undo</button>}
      </div>
    </div>
  );
}
