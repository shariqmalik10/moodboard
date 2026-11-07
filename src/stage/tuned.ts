import { useSyncExternalStore } from "react";
import type { Tuned } from "../demos/tune";

let current: unknown = {};
const listeners = new Set<() => void>();

export function setTuned(values: unknown) {
  current = values;
  for (const listen of listeners) listen();
}

const subscribe = (listen: () => void) => {
  listeners.add(listen);
  return () => listeners.delete(listen);
};

/** A demo reads the dials that feed props with `useTuned<typeof itsDials>()`. */
export const useTuned = <D>() => useSyncExternalStore(subscribe, () => current) as Tuned<D>;
