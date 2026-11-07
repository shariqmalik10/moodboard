import type { ComponentType } from "react";
import type { Dials } from "./tune";

/** A CSS selector, or a selector narrowed by the text inside it. */
export type Target = string | { sel: string; text?: string; nth?: number };

/** One beat of a card's loop. The cursor moves on its own between beats. */
export type Step =
  | { hover: Target; ms?: number }
  | { click: Target; ms?: number; hold?: number }
  | { type: string; cps?: number }
  | { key: string }
  | { scroll: Target; to: number; ms?: number }
  | { wait: number }
  | { leave: true };

export type Script = Step[];

export type Project = string;

/** `arrow` is the drawn cursor set, `touch` is the fingertip dot for a phone, and `none` is for a part that plays by itself. */
export type CursorKind = "arrow" | "touch" | "none";

export type Size = { w: number; h: number };

export type Demo = {
  id: string;
  project: Project;
  title: string;
  /**
   * For a component that is nearly empty until something happens, such as a dialog: how many beats of its
   * script to play before it's seen, so the wall forms it at its best moment instead of at nothing.
   */
  pose?: number;
  /** The iframe's real layout size, so the component's media queries answer truthfully. */
  viewport: Size;
  /** The part of that viewport the card shows, which sets the card's shape. Defaults to all of it. */
  crop?: { x: number; y: number; w: number; h: number };
  dark?: boolean;
  /** What the card is at rest, for a project's own ground colour behind the reveal. */
  ground: string;
  cursor: CursorKind;
  script: Script;
  /** The component's DialKit panel. */
  dials: Dials<any>;
  load: () => Promise<{ default: ComponentType }>;
  /** Where a component from a connected project lives. Its dials edit this file directly. */
  place?: { root: string; file: string; exportName: string };
  /** Runs once the component is on the page, for a loop that depends on what it drew. */
  afterMount?: () => void;
};
