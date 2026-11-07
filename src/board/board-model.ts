export type MaterialKind = "image" | "video";

/** Something added by hand: an image or video with its own shape. `bare` means a cut-out with no card. */
export type Material = { kind: MaterialKind; src: string; title: string; w: number; h: number; bare?: boolean };

/**
 * The wall as stored. Columns hold ids in reading order, so adding something changes one column
 * and the rest of the wall stays exactly where it is. An id is a demo's id or a material's.
 * `hidden` remembers components taken off the wall, so a new one can be told from a removed one.
 */
export type BoardFile = { columns: string[][]; materials: Record<string, Material>; hidden?: string[] };

export type Placement = { column: number; index: number };

const shortest = (columns: string[][]) => columns.reduce((best, column, at) => (column.length < columns[best].length ? at : best), 0);

export function insertItem(board: BoardFile, id: string, material: Material | undefined, at: Placement): BoardFile {
  if (board.columns.some((column) => column.includes(id))) return board;
  const column = at.column >= 0 && at.column < board.columns.length ? at.column : shortest(board.columns);
  const columns = board.columns.map((list, each) => (each === column ? [...list.slice(0, at.index), id, ...list.slice(at.index)] : list));
  return {
    columns,
    materials: material ? { ...board.materials, [id]: material } : board.materials,
    hidden: (board.hidden ?? []).filter((each) => each !== id),
  };
}

export function removeItem(board: BoardFile, id: string): BoardFile {
  const isMaterial = id in board.materials;
  const materials = { ...board.materials };
  delete materials[id];
  return {
    columns: board.columns.map((list) => list.filter((each) => each !== id)),
    materials,
    hidden: isMaterial ? board.hidden : [...(board.hidden ?? []), id],
  };
}
