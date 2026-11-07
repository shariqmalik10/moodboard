/** One exported component found in a project. `hash` covers its file, what it imports, and the global CSS. */
export type Found = {
  id: string;
  title: string;
  /** Path from the project root. */
  file: string;
  exportName: string;
  hash: string;
  /** A sibling `<file>.moodboard.tsx` whose default export is the demo to show instead of sample props. */
  sidecar?: string;
};

/** A value in sample props that JSON can't hold. */
export type Sample = null | boolean | number | string | Sample[] | { [key: string]: Sample } | { __fn: true } | { __date: string };

/** A literal in the project's source that a dial can rewrite. */
export type Literal = {
  /** `group.label`, unique within the component. */
  path: string;
  file: string;
  start: number;
  end: number;
  text: string;
  dial: NumberDial | ColorDial;
  /** Turns a dial value back into the source text that replaces `text`. */
  format: Format;
};

export type NumberDial = { kind: "number"; value: number; min: number; max: number; step: number };
export type ColorDial = { kind: "color"; value: string };

export type Format =
  | { kind: "tailwind"; prefix: string; family: "spacing" | "radius" | "text" | "plain" | "arbitrary"; unit: string; negative: boolean }
  | { kind: "tailwindColor"; prefix: string }
  | { kind: "number" }
  | { kind: "unit"; unit: string }
  | { kind: "stringUnit"; quote: string; unit: string }
  | { kind: "color"; quote: string };

/** One dial's trip through the source, from where it began this session to where it stands. */
export type Change = { path: string; file: string; line: number; from: string; to: string; fromValue: number | string; toValue: number | string };
