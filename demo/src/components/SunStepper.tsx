"use client";

import { useState } from "react";

type SunStepperProps = { hours?: number; max?: number };

/** Hours of direct sun a plant likes. */
export function SunStepper({ hours = 6, max = 12 }: SunStepperProps) {
  const [value, setValue] = useState(hours);
  return (
    <div className="flex w-64 items-center justify-between rounded-[14px] bg-paper p-2">
      <button type="button" aria-label="Less sun" onClick={() => setValue(Math.max(0, value - 1))} className="grid h-10 w-10 place-items-center rounded-[10px] bg-linen text-[20px] active:scale-90 transition-transform">
        −
      </button>
      <div className="flex flex-col items-center">
        <span className="font-display text-[26px] leading-none tabular-nums">{value} h</span>
        <span className="text-[12px] text-loam">of sun a day</span>
      </div>
      <button type="button" aria-label="More sun" onClick={() => setValue(Math.min(max, value + 1))} className="grid h-10 w-10 place-items-center rounded-[10px] bg-linen text-[20px] active:scale-90 transition-transform">
        +
      </button>
    </div>
  );
}
