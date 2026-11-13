import { createHash } from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { applyEdits, formatValue } from "./literals.ts";
import type { Change, Found, Literal } from "./types.ts";

/** How the writer reads and writes source files. The server uses the disk. Tests use memory. */
export type SourceFiles = {
  read(file: string): string;
  write(file: string, text: string): void;
};

/** Writes through a temporary file and a rename, so an editor watching the file never sees half of it. */
export const diskFiles: SourceFiles = {
  read: (file) => fs.readFileSync(file, "utf8"),
  write(file, text) {
    const temporary = `${file}.moodboard-${process.pid}`;
    fs.writeFileSync(temporary, text, { mode: fs.statSync(file).mode });
    fs.renameSync(temporary, file);
  },
};

const sha = (text: string) => createHash("sha1").update(text).digest("hex");
const lineAt = (text: string, at: number) => text.slice(0, at).split("\n").length;

/** Keeps where each dial began. A dial moved back to its start drops out of the journal. */
export function mergeJournal(journalled: Change[], changes: Change[]) {
  const out = new Map(journalled.map((each) => [each.path, each]));
  for (const change of changes) {
    const first = out.get(change.path);
    if (first && first.from === change.to) out.delete(change.path);
    else out.set(change.path, first ? { ...change, from: first.from, fromValue: first.fromValue } : change);
  }
  return [...out.values()];
}

/**
 * Turns dial moves into edits to a project's source. It reads each file fresh, and leaves a literal alone when it
 * no longer says what the panel was shown, so an edit made elsewhere is never overwritten.
 */
export class DialWriter {
  /** What each file held after this writer last wrote it, so a save of our own can be told from a person's. */
  private readonly written = new Map<string, string>();
  /** Per component, the text of each literal as the panel was shown it. */
  private readonly shown = new Map<string, Map<string, string>>();
  /** Per component, what this session's dials have written. */
  private readonly journal = new Map<string, Change[]>();

  constructor(
    private readonly root: string,
    private readonly literalsOf: (component: Found) => Literal[],
    private readonly files: SourceFiles = diskFiles,
  ) {}

  /** Records what the panel is about to show, as the baseline a write is checked against. */
  show(component: Found, literals: Literal[]) {
    this.shown.set(component.id, new Map(literals.map((each) => [each.path, each.text])));
  }

  /** True when every file in this save is exactly what this writer last wrote. */
  wroteAll(files: string[]) {
    return files.every((file) => {
      const ours = this.written.get(file);
      if (ours === undefined) return false;
      try {
        return sha(this.files.read(file)) === ours;
      } catch {
        return false;
      }
    });
  }

  write(component: Found | undefined, values: Record<string, unknown>) {
    if (!component) return { changes: [] as Change[], conflicts: Object.keys(values) };
    const literals = new Map(this.literalsOf(component).map((each) => [each.path, each]));
    const seen = this.shown.get(component.id) ?? new Map<string, string>();
    this.shown.set(component.id, seen);
    const perFile = new Map<string, { literal: Literal; next: string; value: number | string }[]>();
    const conflicts: string[] = [];
    for (const [dial, raw] of Object.entries(values)) {
      const value = raw as number | string;
      const literal = literals.get(dial);
      if (!literal || (seen.has(dial) && seen.get(dial) !== literal.text)) {
        conflicts.push(dial);
        continue;
      }
      if (literal.dial.value === value) continue;
      const next = formatValue(literal.format, value);
      if (next === literal.text) continue;
      perFile.set(literal.file, [...(perFile.get(literal.file) ?? []), { literal, next, value }]);
    }
    const changes: Change[] = [];
    for (const [file, edits] of perFile) {
      const text = this.files.read(file);
      if (edits.some(({ literal }) => text.slice(literal.start, literal.end) !== literal.text)) {
        conflicts.push(...edits.map((each) => each.literal.path));
        continue;
      }
      const after = applyEdits(text, edits.map(({ literal, next }) => ({ start: literal.start, end: literal.end, next })));
      this.written.set(file, sha(after));
      this.files.write(file, after);
      for (const { literal, next, value } of edits) {
        seen.set(literal.path, next);
        changes.push({ path: literal.path, file: path.relative(this.root, file), line: lineAt(after, literal.start), from: literal.text, to: next, fromValue: literal.dial.value, toValue: value });
      }
    }
    if (changes.length > 0) this.journal.set(component.id, mergeJournal(this.journal.get(component.id) ?? [], changes));
    return { changes, conflicts };
  }

  /** What this session's dials have written and the file still says. An edit elsewhere can take a change back. */
  journalNow(component: Found) {
    const literals = new Map(this.literalsOf(component).map((each) => [each.path, each.text]));
    const kept = (this.journal.get(component.id) ?? []).filter((each) => literals.get(each.path) === each.to);
    this.journal.set(component.id, kept);
    return kept;
  }
}
