import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";
import react from "@vitejs/plugin-react";
import { defineConfig, type Plugin } from "vite";
import { boardFile } from "./tools/board-file";

const here = import.meta.dirname;
const shim = (file: string) => path.join(here, "src/stage/shims", file);

/** What a Next.js app takes for granted, swapped for what a card in an iframe needs. */
const SHIMS: Record<string, string> = {
  "next/link": shim("link.tsx"),
  "next/navigation": shim("navigation.ts"),
};

function nextShims(): Plugin {
  return { name: "next-shims", enforce: "pre", resolveId: (source) => SHIMS[source] ?? null };
}

/** Demos that stay on one Mac add their own plugins in `vite.local.mjs`, which git ignores. */
const localFile = path.join(here, "vite.local.mjs");
const local: { plugins: Plugin[]; allow: string[] } = fs.existsSync(localFile) ? await import(pathToFileURL(localFile).href) : { plugins: [], allow: [] };

export default defineConfig({
  base: "./",
  plugins: [react(), ...local.plugins, nextShims(), boardFile(path.join(here, "src/board.json"), path.join(here, "public/material"))],
  resolve: { dedupe: ["react", "react-dom"] },
  server: { port: 5199, fs: { allow: [here, ...local.allow] } },
  preview: { port: 5198 },
  optimizeDeps: { entries: ["index.html", "stage.html", "panel.html", "runtime.html"] },
  build: { rollupOptions: { input: { board: path.join(here, "index.html"), stage: path.join(here, "stage.html"), panel: path.join(here, "panel.html"), runtime: path.join(here, "runtime.html") } } },
});
