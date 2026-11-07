import { useRef, type ChangeEvent } from "react";
import type { Demo, Project } from "../demos/types";
import { HomeIcon, MinusIcon, PlusIcon } from "./icons";
import { CAN_EDIT } from "./useBoard";

export type Filter = "all" | Project;

const FILTERS: { value: Filter; label: string }[] = [
  { value: "all", label: "All" },
];

type Props = {
  filter: Filter;
  zoom: number;
  offWall: Demo[];
  message: string | null;
  inert: boolean;
  onFilter: (filter: Filter) => void;
  onZoom: (factor: number) => void;
  onHome: () => void;
  onFiles: (files: File[]) => void;
  onPlace: (id: string) => void;
};

export function Dock({ filter, zoom, offWall, message, inert, onFilter, onZoom, onHome, onFiles, onPlace }: Props) {
  const panel = useRef<HTMLDivElement>(null);
  const choose = (event: ChangeEvent<HTMLInputElement>) => {
    onFiles(Array.from(event.target.files ?? []));
    event.target.value = "";
    panel.current?.hidePopover();
  };
  return (
    <div className="dock-wrap" inert={inert}>
      {message ? (
        <p className="dock-message" role="status">
          {message}
        </p>
      ) : null}
      <nav className="dock" aria-label="Wall controls">
        <div className="dock-filter" role="radiogroup" aria-label="Show">
          {FILTERS.map(({ value, label }) => (
            <button key={value} type="button" role="radio" aria-checked={filter === value} className="dock-chip" onClick={() => onFilter(value)}>
              {label}
            </button>
          ))}
        </div>
        <span className="dock-rule" />
        <button type="button" className="icon-button" aria-label="Zoom out" onClick={() => onZoom(1 / 1.2)}>
          <MinusIcon />
        </button>
        <output className="dock-zoom" aria-label="Zoom level">
          {Math.round(zoom * 100)}%
        </output>
        <button type="button" className="icon-button" aria-label="Zoom in" onClick={() => onZoom(1.2)}>
          <PlusIcon />
        </button>
        <button type="button" className="icon-button" aria-label="Back to the start" title="Back to the start" onClick={onHome}>
          <HomeIcon />
        </button>
        {CAN_EDIT ? (
          <>
            <span className="dock-rule" />
            <button type="button" className="dock-add" popoverTarget="add-panel">
              <PlusIcon />
              Add
            </button>
          </>
        ) : null}
      </nav>
      {CAN_EDIT ? (
        <div ref={panel} id="add-panel" className="add-panel" popover="auto">
          <h2>Add to the wall</h2>
          <p>Drop images or video anywhere on the wall, or paste them. They land where you let go.</p>
          <label className="text-button add-choose">
            Choose files
            <input type="file" multiple accept="image/*,video/*" hidden onChange={choose} />
          </label>
          <h3 className="caps">Components off the wall · {offWall.length}</h3>
          {offWall.length ? (
            <ul className="add-list">
              {offWall.map((demo) => (
                <li key={demo.id}>
                  <button
                    type="button"
                    className="add-row"
                    onClick={() => {
                      onPlace(demo.id);
                      panel.current?.hidePopover();
                    }}
                  >
                    <span>{demo.title}</span>
                    <span className="add-row-project">{demo.project}</span>
                  </button>
                </li>
              ))}
            </ul>
          ) : (
            <p className="add-empty">Every component is up. To bring in a new one, add a row to its project’s index in src/demos, and its card appears by itself.</p>
          )}
        </div>
      ) : null}
    </div>
  );
}
