"use client";

import { useState } from "react";

type ThirstMeterProps = { label?: string; level?: number; drops?: number };

/** How thirsty a plant gets, set by tapping a drop. */
export function ThirstMeter({ label = "Thirst", level = 3, drops = 5 }: ThirstMeterProps) {
  const [value, setValue] = useState(level);
  return (
    <div className="flex w-72 flex-col gap-3 rounded-[16px] bg-paper p-4">
      <div className="flex justify-between text-[13px]">
        <span className="font-semibold">{label}</span>
        <span className="text-loam">{["Desert", "Dry", "Steady", "Damp", "Swampy"][Math.min(value, 5) - 1] ?? "Desert"}</span>
      </div>
      <div className="flex gap-2" role="radiogroup" aria-label={label}>
        {Array.from({ length: drops }, (_, at) => (
          <button key={at} type="button" role="radio" aria-checked={value === at + 1} aria-label={`${at + 1} of ${drops}`} onClick={() => setValue(at + 1)} className="grid h-10 flex-1 place-items-center rounded-[10px] bg-mist transition-transform active:scale-90">
            <svg width="16" height="20" viewBox="0 0 16 20" aria-hidden="true">
              <path d="M8 1C5 6 2 9.5 2 13a6 6 0 0 0 12 0C14 9.5 11 6 8 1z" fill={at < value ? "#3b7bab" : "transparent"} stroke="#3b7bab" strokeWidth="1.5" style={{ transition: "fill 180ms" }} />
            </svg>
          </button>
        ))}
      </div>
    </div>
  );
}
