"use client";

import { createContext, useCallback, useContext, useState, type ReactNode } from "react";

type Garden = { watered: string[]; water: (plant: string) => void; unwater: (plant: string) => void };

const GardenContext = createContext<Garden | null>(null);

export function GardenProvider({ children }: { children: ReactNode }) {
  const [watered, setWatered] = useState<string[]>([]);
  const water = useCallback((plant: string) => setWatered((all) => (all.includes(plant) ? all : [...all, plant])), []);
  const unwater = useCallback((plant: string) => setWatered((all) => all.filter((each) => each !== plant)), []);
  return <GardenContext.Provider value={{ watered, water, unwater }}>{children}</GardenContext.Provider>;
}

export function useGarden() {
  const garden = useContext(GardenContext);
  if (!garden) throw new Error("useGarden needs a GardenProvider above it.");
  return garden;
}
