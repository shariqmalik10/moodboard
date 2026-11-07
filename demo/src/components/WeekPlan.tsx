"use client";

import { useState } from "react";

type WeekPlanProps = { waterOn?: number[] };

const DAYS = ["M", "T", "W", "T", "F", "S", "S"];

/** The days of the week this plant gets water. Tap a day to change it. */
export function WeekPlan({ waterOn = [0, 3] }: WeekPlanProps) {
  const [days, setDays] = useState(waterOn);
  const toggle = (day: number) => setDays(days.includes(day) ? days.filter((each) => each !== day) : [...days, day]);
  return (
    <div className="flex w-80 flex-col gap-3 rounded-[16px] bg-paper p-4">
      <span className="text-[13px] text-loam">{days.length === 0 ? "Never watered" : `Watered ${days.length} ${days.length === 1 ? "day" : "days"} a week`}</span>
      <div className="flex justify-between">
        {DAYS.map((label, day) => {
          const on = days.includes(day);
          return (
            <button key={day} type="button" aria-pressed={on} aria-label={`Day ${day + 1}`} onClick={() => toggle(day)} className="grid h-9 w-9 place-items-center rounded-full text-[13px] font-semibold transition-colors duration-200" style={{ backgroundColor: on ? "#3b7bab" : "#f1eee4", color: on ? "white" : "#6b6458" }}>
              {label}
            </button>
          );
        })}
      </div>
    </div>
  );
}
