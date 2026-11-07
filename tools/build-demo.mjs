import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { copyPackages } from "./copy-packages.mjs";

// Packs the Greenhouse demo the app offers on first launch. It carries only what Moodboard needs to run its
// components, so it works offline. Next itself is left out, and `npm install` in the copy brings it back.
const repo = path.resolve(import.meta.dirname, "..");
const demo = path.join(repo, "demo");
const out = path.join(repo, "dist-demo");
const RUNTIME = ["react", "react-dom", "tailwindcss", "@tailwindcss/postcss", "@types/react", "@types/react-dom"];
const LEFT_OUT = ["node_modules", ".next", "next-env.d.ts", "tsconfig.tsbuildinfo"];

if (!fs.existsSync(path.join(demo, "node_modules"))) execFileSync("npm", ["ci", "--no-audit", "--no-fund"], { cwd: demo, stdio: "inherit" });

fs.rmSync(out, { recursive: true, force: true });
fs.cpSync(demo, out, { recursive: true, filter: (source) => !LEFT_OUT.includes(path.basename(source)) });
const { count, megabytes } = copyPackages(RUNTIME, demo, out);
console.log(`dist-demo: ${count} packages, ${megabytes} MB`);
