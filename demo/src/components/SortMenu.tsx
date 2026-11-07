"use client";

import { useEffect, useRef, useState } from "react";

type SortMenuProps = { options?: string[] };

export function SortMenu({ options = ["Thirstiest", "Name", "Room"] }: SortMenuProps) {
  const [open, setOpen] = useState(false);
  const [chosen, setChosen] = useState(options[0]);
  const box = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!open) return;
    const close = (event: PointerEvent) => !box.current?.contains(event.target as Node) && setOpen(false);
    const escape = (event: KeyboardEvent) => event.key === "Escape" && setOpen(false);
    addEventListener("pointerdown", close);
    addEventListener("keydown", escape);
    return () => {
      removeEventListener("pointerdown", close);
      removeEventListener("keydown", escape);
    };
  }, [open]);

  return (
    <div ref={box} className="relative w-60">
      <button type="button" aria-haspopup="menu" aria-expanded={open} onClick={() => setOpen(!open)} className="flex w-full items-center justify-between rounded-[12px] border border-rule bg-paper px-4 py-3 text-[14px]">
        <span>
          <span className="text-loam">Sort by </span>
          <span className="font-semibold">{chosen}</span>
        </span>
        <span className="text-loam transition-transform duration-200" style={{ transform: open ? "rotate(180deg)" : "none" }}>⌄</span>
      </button>
      <div role="menu" className="absolute inset-x-0 top-full mt-2 origin-top rounded-[12px] border border-rule bg-paper p-1 shadow-[0_12px_30px_rgba(38,35,29,0.12)] transition-[opacity,transform] duration-150" style={{ opacity: open ? 1 : 0, transform: open ? "none" : "translateY(-4px) scale(0.98)", pointerEvents: open ? "auto" : "none" }}>
        {options.map((option) => (
          <button key={option} type="button" role="menuitemradio" aria-checked={chosen === option} onClick={() => { setChosen(option); setOpen(false); }} className="flex w-full items-center justify-between rounded-[8px] px-3 py-2 text-left text-[14px] hover:bg-linen">
            {option}
            {chosen === option && <span className="text-leaf">✓</span>}
          </button>
        ))}
      </div>
    </div>
  );
}
