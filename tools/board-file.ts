import { createHash } from "node:crypto";
import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import path from "node:path";
import type { IncomingMessage, ServerResponse } from "node:http";
import type { Plugin } from "vite";
import { insertItem, removeItem, type BoardFile, type MaterialKind } from "../src/board/board-model";

const EXTENSIONS: Record<string, MaterialKind> = {
  ".png": "image",
  ".jpg": "image",
  ".jpeg": "image",
  ".webp": "image",
  ".gif": "image",
  ".avif": "image",
  ".svg": "image",
  ".mp4": "video",
  ".webm": "video",
  ".mov": "video",
};

function body(request: IncomingMessage) {
  return new Promise<Buffer>((resolve, reject) => {
    const parts: Buffer[] = [];
    request.on("data", (part: Buffer) => parts.push(part));
    request.on("end", () => resolve(Buffer.concat(parts)));
    request.on("error", reject);
  });
}

const slug = (name: string) =>
  path
    .basename(name, path.extname(name))
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-|-$/g, "")
    .slice(0, 48) || "material";

type Handler = (request: IncomingMessage, response: ServerResponse) => Promise<void>;

/** A failed request answers with its reason. It must never take the dev server down with it. */
const guarded = (handler: Handler) => (request: IncomingMessage, response: ServerResponse) => {
  const origin = request.headers.origin;
  if (request.method !== "POST" || (origin && new URL(origin).host !== request.headers.host)) {
    response.statusCode = 403;
    response.end(JSON.stringify({ error: "Only this wall can change the board." }));
    return;
  }
  handler(request, response).catch((reason: unknown) => {
    response.statusCode = 500;
    response.end(JSON.stringify({ error: reason instanceof Error ? reason.message : "The board couldn't be saved." }));
  });
};

/**
 * While running locally, the board is a file: what you add is written to `src/board.json` and
 * `public/material/`, and Vite's hot reload is what shows it on the wall. A built site has neither
 * endpoint, so the published wall is read-only and shows exactly what was on the board at build.
 */
export function boardFile(boardPath: string, materialDir: string): Plugin {
  // One change at a time, each swapped in whole: a burst of drops can't lose an update, and nothing
  // reading the file, this server or Vite's own watcher, ever sees it half written.
  let queue: Promise<unknown> = Promise.resolve();
  const change = (next: (board: BoardFile) => BoardFile) => {
    const done = queue.then(async () => {
      const board = JSON.parse(await readFile(boardPath, "utf8")) as BoardFile;
      const scratch = `${boardPath}.${process.pid}.tmp`;
      await writeFile(scratch, `${JSON.stringify(next(board), null, 2)}\n`);
      await rename(scratch, boardPath);
    });
    queue = done.catch(() => undefined);
    return done;
  };

  return {
    name: "board-file",
    apply: "serve",
    configureServer(server) {
      server.middlewares.use(
        "/__board/material",
        guarded(async (request, response) => {
          const url = new URL(request.url ?? "", "http://local");
          const name = url.searchParams.get("name") ?? "material";
          const ext = path.extname(name).toLowerCase();
          const kind = EXTENSIONS[ext];
          if (!kind) {
            response.statusCode = 400;
            response.end(JSON.stringify({ error: `Can't add a ${ext || "file with no extension"} to the board.` }));
            return;
          }
          const bytes = await body(request);
          const hash = createHash("sha1").update(bytes).digest("hex").slice(0, 8);
          const file = `${slug(name)}-${hash}${ext}`;
          await mkdir(materialDir, { recursive: true });
          await writeFile(path.join(materialDir, file), bytes);
          const id = `material/${file}`;
          const material = { kind, src: `material/${file}`, title: path.basename(name, ext), w: Number(url.searchParams.get("w")) || 1, h: Number(url.searchParams.get("h")) || 1, ...(url.searchParams.get("bare") ? { bare: true } : {}) };
          await change((board) => insertItem(board, id, material, { column: Number(url.searchParams.get("column") ?? -1), index: Number(url.searchParams.get("index") ?? 0) }));
          response.setHeader("content-type", "application/json");
          response.end(JSON.stringify({ id }));
        }),
      );

      server.middlewares.use(
        "/__board/place",
        guarded(async (request, response) => {
          const { id, column, index } = JSON.parse((await body(request)).toString()) as { id: string; column?: number; index?: number };
          await change((board) => insertItem(board, id, undefined, { column: column ?? -1, index: index ?? 0 }));
          response.end("{}");
        }),
      );

      server.middlewares.use(
        "/__board/remove",
        guarded(async (request, response) => {
          const { id } = JSON.parse((await body(request)).toString()) as { id: string };
          await change((board) => removeItem(board, id));
          response.end("{}");
        }),
      );
    },
  };
}
