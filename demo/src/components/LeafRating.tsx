"use client";

import { useState } from "react";

type LeafRatingProps = { label?: string; leaves?: number };

/** How happy the plant looks, in leaves. */
export function LeafRating({ label = "How it looks this week", leaves = 4 }: LeafRatingProps) {
  const [value, setValue] = useState(leaves);
  const [hover, setHover] = useState<number | null>(null);
  const shown = hover ?? value;
  return (
    <div className="flex flex-col items-start gap-2">
      <span className="text-[13px] text-loam">{label}</span>
      <div className="flex gap-1" onPointerLeave={() => setHover(null)}>
        {Array.from({ length: 5 }, (_, at) => (
          <button key={at} type="button" aria-label={`${at + 1} leaves`} onPointerEnter={() => setHover(at + 1)} onClick={() => setValue(at + 1)} className="transition-transform duration-150 hover:scale-110 active:scale-90">
            <svg width="30" height="30" viewBox="0 0 30 30" aria-hidden="true">
              <path d="M6 24C6 12 13 5 25 5c0 12-7 19-19 19z" fill={at < shown ? "#3d6a46" : "#ddd7c8"} style={{ transition: "fill 150ms" }} />
              <path d="M6 24L19 11" stroke="#fbfaf5" strokeWidth="1.4" strokeLinecap="round" />
            </svg>
          </button>
        ))}
      </div>
    </div>
  );
}
