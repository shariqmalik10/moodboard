"use client";

import { useEffect, useRef, useState } from "react";
import { useGarden } from "@/app/providers";

type WaterButtonProps = {
  plant?: string;
  /** How long to hold before the plant counts as watered, in milliseconds. */
  holdFor?: number;
};

/** Press and hold to water. Letting go early pours nothing. */
export function WaterButton({ plant = "Calathea", holdFor = 900 }: WaterButtonProps) {
  const { watered, water, unwater } = useGarden();
  const [filling, setFilling] = useState(false);
  const timer = useRef<ReturnType<typeof setTimeout>>(undefined);
  const done = watered.includes(plant);

  useEffect(() => () => clearTimeout(timer.current), []);

  const start = () => {
    if (done) return unwater(plant);
    setFilling(true);
    timer.current = setTimeout(() => {
      water(plant);
      setFilling(false);
    }, holdFor);
  };
  const stop = () => {
    clearTimeout(timer.current);
    setFilling(false);
  };

  return (
    <button
      type="button"
      onPointerDown={start}
      onPointerUp={stop}
      onPointerLeave={stop}
      className="relative h-14 w-64 overflow-hidden rounded-[16px] border border-water/30 bg-mist text-[15px] font-semibold text-water select-none active:scale-[0.98] transition-transform"
    >
      <span
        className="absolute inset-y-0 left-0 bg-water/25"
        style={{ width: filling || done ? "100%" : "0%", transition: `width ${filling ? holdFor : 200}ms linear` }}
      />
      <span className="relative">{done ? `${plant} is watered` : filling ? "Pouring…" : `Hold to water ${plant}`}</span>
    </button>
  );
}
