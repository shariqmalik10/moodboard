"use client";

import { useState } from "react";

type Note = { title: string; body: string };
type CareNotesProps = { notes?: Note[] };

const NOTES: Note[] = [
  { title: "Light", body: "Bright, indirect light. A metre from a south window is plenty." },
  { title: "Water", body: "When the top two centimetres of soil are dry. Less in winter." },
  { title: "Leaves", body: "Wipe them once a month so they can breathe." },
];

export function CareNotes({ notes = NOTES }: CareNotesProps) {
  const [open, setOpen] = useState<number | null>(0);
  return (
    <div className="w-80 divide-y divide-rule rounded-[16px] border border-rule bg-paper">
      {notes.map((note, at) => (
        <div key={note.title}>
          <button type="button" aria-expanded={open === at} onClick={() => setOpen(open === at ? null : at)} className="flex w-full items-center justify-between px-4 py-3 text-left text-[15px] font-semibold">
            {note.title}
            <span className="text-loam transition-transform duration-200" style={{ transform: open === at ? "rotate(45deg)" : "none" }}>+</span>
          </button>
          <div className="grid transition-[grid-template-rows] duration-300" style={{ gridTemplateRows: open === at ? "1fr" : "0fr" }}>
            <p className="overflow-hidden px-4 text-[14px] leading-relaxed text-loam" style={{ paddingBottom: open === at ? 14 : 0 }}>{note.body}</p>
          </div>
        </div>
      ))}
    </div>
  );
}
