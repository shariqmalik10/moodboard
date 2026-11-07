"use client";

import { useState } from "react";

type PlantSearchProps = { placeholder?: string; plants?: string[] };

export function PlantSearch({ placeholder = "Find a plant", plants = ["Monstera", "Fiddle leaf fig", "Snake plant", "Pothos", "Calathea"] }: PlantSearchProps) {
  const [query, setQuery] = useState("");
  const found = query ? plants.filter((plant) => plant.toLowerCase().includes(query.toLowerCase())) : [];
  return (
    <div className="flex w-80 flex-col gap-2">
      <div className="flex items-center gap-2 rounded-[14px] border border-rule bg-paper px-4 py-3 focus-within:border-leaf">
        <svg width="16" height="16" viewBox="0 0 16 16" aria-hidden="true"><circle cx="7" cy="7" r="5" stroke="#6b6458" strokeWidth="1.6" fill="none" /><path d="M11 11l3.5 3.5" stroke="#6b6458" strokeWidth="1.6" strokeLinecap="round" /></svg>
        <input value={query} onChange={(event) => setQuery(event.target.value)} placeholder={placeholder} aria-label={placeholder} className="flex-1 bg-transparent text-[15px] outline-none placeholder:text-loam" />
        {query && <button type="button" aria-label="Clear" onClick={() => setQuery("")} className="text-loam">×</button>}
      </div>
      {query && (
        <ul className="rounded-[14px] bg-paper p-1 text-[14px]">
          {found.length === 0 ? <li className="px-3 py-2 text-loam">No plant called “{query}”</li> : found.map((plant) => <li key={plant} className="rounded-[10px] px-3 py-2 hover:bg-linen">{plant}</li>)}
        </ul>
      )}
    </div>
  );
}
