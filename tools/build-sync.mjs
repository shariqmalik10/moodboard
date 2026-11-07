import { build } from "esbuild";
import fs from "node:fs";
import path from "node:path";
import { copyPackages } from "./copy-packages.mjs";

// Packs what the app needs to run a project's dev server: the server itself, the stage it serves, and the
// packages it runs on, copied from this repo's node_modules so the versions match what was tested.
const repo = path.resolve(import.meta.dirname, "..");
const out = path.join(repo, "dist-sync");
const RUNTIME = ["vite", "@vitejs/plugin-react", "typescript", "postcss"];

fs.rmSync(out, { recursive: true, force: true });
fs.mkdirSync(out, { recursive: true });
await build({ entryPoints: [path.join(repo, "sync/server.ts")], outfile: path.join(out, "server.mjs"), bundle: true, platform: "node", format: "esm", packages: "external", logLevel: "warning" });

const assets = ["src/stage", "src/demos/tune.ts", "src/demos/types.ts", "sync/client", "public/cursors"];
for (const each of assets) fs.cpSync(path.join(repo, each), path.join(out, "assets", each), { recursive: true });

const { count, megabytes } = copyPackages(RUNTIME, repo, out, { peers: ["vite", "esbuild"] });
console.log(`dist-sync: ${count} packages, ${megabytes} MB`);
