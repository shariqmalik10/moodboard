import { describe, expect, it } from "vitest";
import { readComponent } from "./literals.ts";
import type { Change, Found } from "./types.ts";
import { DialWriter, mergeJournal, type SourceFiles } from "./writer.ts";

const FILE = "/project/Card.tsx";
const SOURCE = `export function Card() {\n  return <div className="p-4 rounded-lg">Card</div>;\n}\n`;
const component: Found = { id: "project/demo/Card.tsx/Card", title: "Card", file: "Card.tsx", exportName: "Card", hash: "a" };

function setUp(text = SOURCE) {
  const disk = new Map([[FILE, text]]);
  const files: SourceFiles = {
    read: (file) => disk.get(file) ?? "",
    write: (file, next) => void disk.set(file, next),
  };
  const literalsOf = () => readComponent(disk.get(FILE) ?? "", FILE, "Card").literals;
  const writer = new DialWriter("/project", literalsOf, files);
  const dial = (prefix: string) => literalsOf().find((each) => each.path.endsWith(prefix))?.path ?? "";
  return { disk, writer, literalsOf, dial };
}

describe("writing dials into the source", () => {
  it("rewrites the literal, keeps the scale name when it can, and journals the change", () => {
    const { disk, writer, dial } = setUp();
    const padding = dial("padding");
    const result = writer.write(component, { [padding]: 24 });
    expect(result.conflicts).toEqual([]);
    expect(disk.get(FILE)).toContain(`className="p-6 rounded-lg"`);
    expect(result.changes).toMatchObject([{ path: padding, file: "Card.tsx", line: 2, from: "p-4", to: "p-6", fromValue: 16, toValue: 24 }]);
    expect(writer.journalNow(component)).toHaveLength(1);
  });

  it("knows its own write from a person's save", () => {
    const { disk, writer, dial } = setUp();
    writer.write(component, { [dial("padding")]: 24 });
    expect(writer.wroteAll([FILE])).toBe(true);
    disk.set(FILE, `${disk.get(FILE)}// edited\n`);
    expect(writer.wroteAll([FILE])).toBe(false);
  });

  it("refuses a dial whose literal changed since the panel was shown it", () => {
    const { disk, writer, dial, literalsOf } = setUp();
    const padding = dial("padding");
    writer.show(component, literalsOf());
    disk.set(FILE, SOURCE.replace("p-4", "p-8"));
    const result = writer.write(component, { [padding]: 24 });
    expect(result.conflicts).toEqual([padding]);
    expect(disk.get(FILE)).toContain("p-8");
  });

  it("calls every dial a conflict for a component it can't find", () => {
    const { writer } = setUp();
    expect(writer.write(undefined, { a: 1, b: 2 })).toEqual({ changes: [], conflicts: ["a", "b"] });
  });

  it("drops a journal entry once an edit elsewhere takes the change back", () => {
    const { disk, writer, dial } = setUp();
    writer.write(component, { [dial("padding")]: 24 });
    disk.set(FILE, SOURCE);
    expect(writer.journalNow(component)).toEqual([]);
  });
});

describe("the journal", () => {
  const change = (from: string, to: string): Change => ({ path: "Spacing.padding", file: "Card.tsx", line: 2, from, to, fromValue: from, toValue: to });

  it("keeps where a dial began across several moves", () => {
    expect(mergeJournal([change("p-4", "p-6")], [change("p-6", "p-8")])).toEqual([{ ...change("p-6", "p-8"), from: "p-4", fromValue: "p-4" }]);
  });

  it("forgets a dial moved back to where it began", () => {
    expect(mergeJournal([change("p-4", "p-6")], [change("p-6", "p-4")])).toEqual([]);
  });
});
