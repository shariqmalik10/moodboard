"use client";

import { useState } from "react";

type RoomTabsProps = { rooms?: string[] };

export function RoomTabs({ rooms = ["Kitchen", "Bedroom", "Balcony"] }: RoomTabsProps) {
  const [active, setActive] = useState(0);
  return (
    <div role="tablist" className="relative flex w-80 rounded-[14px] bg-paper p-1">
      <span className="absolute top-1 bottom-1 rounded-[10px] bg-sprout transition-[left] duration-300 ease-[cubic-bezier(0.2,0.8,0.2,1)]" style={{ left: `calc(${(active / rooms.length) * 100}% + 4px)`, width: `calc(${100 / rooms.length}% - 8px)` }} />
      {rooms.map((room, at) => (
        <button key={room} type="button" role="tab" aria-selected={active === at} onClick={() => setActive(at)} className="relative flex-1 py-2 text-[14px] font-semibold transition-colors" style={{ color: active === at ? "#3d6a46" : "#6b6458" }}>
          {room}
        </button>
      ))}
    </div>
  );
}
