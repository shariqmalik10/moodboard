"use client";

import { useState } from "react";

type MistToggleProps = { label?: string; detail?: string; on?: boolean };

export function MistToggle({ label = "Morning mist", detail = "A light spray at 8 am", on = true }: MistToggleProps) {
  const [isOn, setOn] = useState(on);
  return (
    <label className="flex w-80 cursor-pointer items-center justify-between gap-4 rounded-[16px] border border-rule bg-paper px-4 py-3">
      <span className="flex flex-col">
        <span className="text-[15px] font-semibold">{label}</span>
        <span className="text-[13px] text-loam">{detail}</span>
      </span>
      <button
        type="button"
        role="switch"
        aria-checked={isOn}
        onClick={() => setOn(!isOn)}
        className="relative h-7 w-12 shrink-0 rounded-full transition-colors duration-200"
        style={{ backgroundColor: isOn ? "#3d6a46" : "#ddd7c8" }}
      >
        <span className="absolute top-1 left-1 h-5 w-5 rounded-full bg-white shadow transition-transform duration-200" style={{ transform: isOn ? "translateX(20px)" : "none" }} />
      </button>
    </label>
  );
}
