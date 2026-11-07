"use client";

import { useGarden } from "@/app/providers";
import { Leaf } from "./Leaf";

type PlantCardProps = {
  name?: string;
  room?: string;
  /** Days since it was last watered. */
  dryFor?: number;
  /** Days it can go without water. */
  thirstyAfter?: number;
};

export function PlantCard({ name = "Monstera", room = "Kitchen window", dryFor = 6, thirstyAfter = 7 }: PlantCardProps) {
  const { watered, water } = useGarden();
  const isWatered = watered.includes(name);
  const level = isWatered ? 0 : Math.min(dryFor / thirstyAfter, 1);
  const thirsty = level >= 0.8;

  return (
    <article className="flex w-80 flex-col gap-4 rounded-[20px] border border-rule bg-paper p-5 shadow-[0_10px_30px_rgba(38,35,29,0.08)]">
      <div className="flex items-start justify-between">
        <div className="flex flex-col gap-1">
          <h3 className="font-display text-[22px] leading-tight">{name}</h3>
          <p className="text-[13px] text-loam">{room}</p>
        </div>
        <Leaf size={52} />
      </div>
      <div className="h-2 overflow-hidden rounded-full bg-linen">
        <div className="h-full rounded-full transition-[width,background-color] duration-500" style={{ width: `${Math.max(level, 0.04) * 100}%`, backgroundColor: thirsty ? "#c2653d" : "#3b7bab" }} />
      </div>
      <div className="flex items-center justify-between">
        <span className="text-[13px] text-loam">{isWatered ? "Watered just now" : thirsty ? "Thirsty today" : `Fine for ${Math.max(thirstyAfter - dryFor, 1)} more days`}</span>
        <button type="button" onClick={() => water(name)} disabled={isWatered} className="rounded-[10px] bg-leaf px-4 py-2 text-[13px] font-semibold text-white transition-opacity disabled:opacity-40">
          Water
        </button>
      </div>
    </article>
  );
}
