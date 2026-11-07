/** What the wall tells a card's stage. `saved` is DialKit's dotted values, from the app. */
export type HostMessage = { type: "run"; run: boolean } | { type: "replay" } | { type: "drive" } | { type: "reset" } | { type: "watch" } | { type: "tune"; saved: Record<string, unknown> };

/** What a card's stage tells the wall. */
export type StageMessage = { type: "ready"; id: string } | { type: "driving"; id: string } | { type: "escape"; id: string } | { type: "failed"; id: string; message: string } | { type: "measured"; id: string; width: number; height: number; ground: string; blank: boolean };
