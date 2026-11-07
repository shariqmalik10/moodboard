import { createHash, randomBytes } from "node:crypto";
import fs from "node:fs";
import type { IncomingMessage, ServerResponse } from "node:http";
import path from "node:path";
import react from "@vitejs/plugin-react";
import { createServer, type Plugin } from "vite";
import { applyEdits, dialConfig, formatValue, readComponent, readCss } from "./literals.ts";
import { Samples } from "./samples.ts";
import { Scanner } from "./scan.ts";
import type { Change, Found, Literal, Sample } from "./types.ts";

const argument = (name: string) => {
  const at = process.argv.indexOf(`--${name}`);
  return at >= 0 ? process.argv[at + 1] : undefined;
};

const root = path.resolve(argument("root") ?? process.cwd());
const support = path.resolve(argument("support") ?? path.join(root, ".moodboard"));
const here = path.resolve(argument("assets") ?? path.join(import.meta.dirname, ".."));
const token = argument("token") ?? process.env.MOODBOARD_TOKEN ?? randomBytes(16).toString("hex");
const stage = path.join(here, "src/stage");
const shims = path.join(stage, "shims");
const client = path.join(here, "sync/client");
/** The panel's folder for props the wall made up, named so nobody takes them for the real data. */
const SAMPLE_FOLDER = "Sample props";

// A real component runs in a loop here, and the loop presses its buttons. Nothing it does may reach a real backend, leave the page, or open another.
const PAGE_GUARD = `(() => {
  const reads = (method) => !method || /^(GET|HEAD)$/i.test(method);
  const fetchFirst = window.fetch.bind(window);
  window.fetch = (input, init) => reads(init?.method ?? input?.method) ? fetchFirst(input, init) : Promise.resolve(new Response("{}", { status: 503 }));
  const openFirst = XMLHttpRequest.prototype.open;
  const sendFirst = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function (method, ...rest) { this.__refused = !reads(method); return openFirst.call(this, method, ...rest); };
  XMLHttpRequest.prototype.send = function (body) { if (this.__refused) { this.abort(); return; } return sendFirst.call(this, body); };
  navigator.sendBeacon = () => true;
  window.open = () => null;
  addEventListener("click", (event) => { if (event.target.closest?.("a[href]")) event.preventDefault(); }, true);
  addEventListener("submit", (event) => event.preventDefault(), true);
})();`;

const say = (message: Record<string, unknown>) => process.stdout.write(`${JSON.stringify(message)}\n`);

// The app shows the last thing the server said before it stopped, and a Node stack trace ends on a version line.
process.on("uncaughtException", (reason: NodeJS.ErrnoException) => {
  const refused = reason.code === "EPERM" || reason.code === "EACCES";
  say({ type: "failed", message: refused ? "Moodboard can't read this folder. If macOS asks, choose Allow, or turn Moodboard on in System Settings, under Privacy & Security, Files and Folders." : reason.message });
  process.exit(1);
});

const [major = 0, minor = 0] = process.versions.node.split(".").map(Number);
if (major < 20 || (major === 20 && minor < 19)) {
  console.error(`This project needs Node 20.19 or newer, and the node on your PATH is ${process.versions.node}.`);
  process.exit(1);
}

const scanner = new Scanner(root, argument("slug"));
scanner.scan();
const samples = new Samples(root, scanner.options, () => scanner.sourceFiles());
let found: Found[] = [];
const byId = () => new Map(found.map((each) => [each.id, each]));

const sha = (text: string) => createHash("sha1").update(text).digest("hex");
const writtenByUs = new Map<string, string>();
const known = new Map<string, Map<string, string>>();
const journal = new Map<string, Change[]>();

function literalsOf(component: Found): Literal[] {
  const file = path.join(root, component.file);
  const { literals, classes } = readComponent(fs.readFileSync(file, "utf8"), file, component.exportName);
  const stylesheets = new Set([...scanner.importedCss(file), ...scanner.globalCssFiles()]);
  for (const sheet of stylesheets) {
    try {
      readCss(fs.readFileSync(sheet, "utf8"), sheet, classes, literals);
    } catch {}
  }
  return literals;
}

const sampleCache = new Map<string, { hash: string; props: Record<string, Sample>; dials: Record<string, unknown> }>();
function sampleOf(component: Found) {
  const cached = sampleCache.get(component.id);
  if (cached?.hash === component.hash) return cached;
  let made: { props: Record<string, Sample>; dials: Record<string, unknown> } = { props: {}, dials: {} };
  try {
    made = samples.forExport(path.join(root, component.file), component.exportName);
  } catch (reason) {
    say({ type: "log", message: `Sample props for ${component.id}: ${String(reason)}` });
  }
  const entry = { hash: component.hash, ...made };
  sampleCache.set(component.id, entry);
  return entry;
}

function publish(files: string[], bySelf: boolean) {
  found = scanner.components();
  const changed = new Set(found.filter((each) => sampleCache.has(each.id) && sampleCache.get(each.id)?.hash !== each.hash).map((each) => each.id));
  for (const module of server.moduleGraph.idToModuleMap.values()) {
    if (!module.id?.startsWith("/@moodboard/component")) continue;
    if (changed.has(new URLSearchParams(module.id.split("?")[1]).get("id") ?? "")) server.moduleGraph.invalidateModule(module);
  }
  say({ type: "components", name: scanner.name, slug: scanner.slug, items: found, files: files.map((each) => path.relative(root, each)), bySelf });
}

let pendingFiles = new Set<string>();
let pendingTimer: NodeJS.Timeout | undefined;
function fileChanged(file: string) {
  scanner.fileChanged(file);
  samples.touched(file);
  pendingFiles.add(file);
  clearTimeout(pendingTimer);
  pendingTimer = setTimeout(() => {
    const files = [...pendingFiles];
    pendingFiles = new Set();
    const bySelf = files.every((each) => {
      if (!writtenByUs.has(each)) return false;
      try {
        return sha(fs.readFileSync(each, "utf8")) === writtenByUs.get(each);
      } catch {
        return false;
      }
    });
    publish(files, bySelf);
  }, 30);
}

const json = (response: ServerResponse, value: unknown, status = 200) => {
  response.statusCode = status;
  response.setHeader("Content-Type", "application/json");
  response.end(JSON.stringify(value));
};

const readBody = (request: IncomingMessage) =>
  new Promise<string>((resolve, reject) => {
    let body = "";
    request.on("data", (chunk) => (body += chunk));
    request.on("end", () => resolve(body));
    request.on("error", reject);
  });

const line = (text: string, at: number) => text.slice(0, at).split("\n").length;

/** Writes dial values into the source. Reads the file fresh each time, and leaves a literal alone if it no longer says what the panel was shown. */
function write(id: string, values: Record<string, unknown>) {
  const component = byId().get(id);
  if (!component) return { changes: [] as Change[], conflicts: Object.keys(values) };
  const literals = new Map(literalsOf(component).map((each) => [each.path, each]));
  const seen = (known.get(id) ?? new Map<string, string>());
  known.set(id, seen);
  const perFile = new Map<string, { literal: Literal; next: string; value: unknown }[]>();
  const conflicts: string[] = [];
  for (const [dial, value] of Object.entries(values)) {
    const literal = literals.get(dial);
    if (!literal) {
      conflicts.push(dial);
      continue;
    }
    if (seen.has(dial) && seen.get(dial) !== literal.text) {
      conflicts.push(dial);
      continue;
    }
    if (literal.dial.value === value) continue;
    const next = formatValue(literal.format, value as number | string);
    if (next === literal.text) continue;
    const edits = perFile.get(literal.file) ?? [];
    edits.push({ literal, next, value });
    perFile.set(literal.file, edits);
  }
  const changes: Change[] = [];
  for (const [file, edits] of perFile) {
    const text = fs.readFileSync(file, "utf8");
    if (edits.some(({ literal }) => text.slice(literal.start, literal.end) !== literal.text)) {
      conflicts.push(...edits.map((each) => each.literal.path));
      continue;
    }
    const after = applyEdits(text, edits.map(({ literal, next }) => ({ start: literal.start, end: literal.end, next })));
    writtenByUs.set(file, sha(after));
    const temporary = `${file}.moodboard-${process.pid}`;
    fs.writeFileSync(temporary, after, { mode: fs.statSync(file).mode });
    fs.renameSync(temporary, file);
    for (const { literal, next, value } of edits) {
      seen.set(literal.path, next);
      changes.push({ path: literal.path, file: path.relative(root, file), line: line(after, literal.start), from: literal.text, to: next, fromValue: literal.dial.value, toValue: value as number | string });
    }
  }
  if (changes.length > 0) journal.set(id, mergeJournal(journal.get(id) ?? [], changes));
  return { changes, conflicts };
}

/** Keeps where each dial began. A dial that came back to it has nothing left to say. */
function mergeJournal(journalled: Change[], changes: Change[]) {
  const out = new Map(journalled.map((each) => [each.path, each]));
  for (const change of changes) {
    const first = out.get(change.path);
    if (first && first.from === change.to) out.delete(change.path);
    else out.set(change.path, first ? { ...change, from: first.from, fromValue: first.fromValue } : change);
  }
  return [...out.values()];
}

/** What this session's dials have written and the file still says. An edit elsewhere can take a change back. */
function journalNow(component: Found) {
  const literals = new Map(literalsOf(component).map((each) => [each.path, each.text]));
  const kept = (journal.get(component.id) ?? []).filter((each) => literals.get(each.path) === each.to);
  journal.set(component.id, kept);
  return kept;
}

const asModulePath = (file: string) => JSON.stringify(file);

function componentModule(component: Found) {
  const file = asModulePath(path.join(root, component.file));
  const providers = scanner.layout.providers.filter((each) => !(each.module === path.join(root, component.file) && each.exportName === component.exportName));
  const providerImports = providers.map((each, at) => (each.exportName === "default" ? `import Provider${at} from ${asModulePath(each.module)};` : `import { ${each.exportName} as Provider${at} } from ${asModulePath(each.module)};`));
  const wrap = (inner: string) => providers.reduceRight((body, each, at) => `createElement(Provider${at}, { ${Object.entries(each.attributes).map(([key, value]) => `${JSON.stringify(key)}: ${value}`).join(", ")} }, ${body})`, inner);
  if (component.sidecar) {
    return `
import { createElement } from "react";
import Target from ${asModulePath(path.join(root, component.sidecar))};
${providerImports.join("\n")}
export default function Demo() {
  return ${wrap("createElement(Target)")};
}`;
  }
  const target = component.exportName === "default" ? `import Target from ${file};` : `import { ${component.exportName} as Target } from ${file};`;
  return `
import { createElement } from "react";
import { useTuned } from ${asModulePath(path.join(stage, "tuned.ts"))};
${target}
${providerImports.join("\n")}
const revive = (value) => {
  if (Array.isArray(value)) return value.map(revive);
  if (value && typeof value === "object") {
    if (value.__fn) return () => {};
    if (value.__date) return new Date(value.__date);
    return Object.fromEntries(Object.entries(value).map(([key, each]) => [key, revive(each)]));
  }
  return value;
};
const sample = revive(${JSON.stringify(sampleOf(component).props)});
export default function Demo() {
  const tuned = useTuned();
  return ${wrap(`createElement(Target, { ...sample, ...(tuned?.[${JSON.stringify(SAMPLE_FOLDER)}] ?? {}) })`)};
}`;
}

function globalsModule() {
  const { css, bodyClass, fonts } = scanner.layout;
  const lines = [...css.map((each) => `import ${JSON.stringify(each)};`)];
  lines.push(`import { applyFont } from ${asModulePath(path.join(client, "font.ts"))};`);
  for (const font of fonts) lines.push(`applyFont(${JSON.stringify(font.family)}, ${JSON.stringify(font.source)}, ${font.options.includes("src:") ? "{}" : font.options});`);
  lines.push(`document.body.className = ${JSON.stringify(bodyClass)};`);
  return lines.join("\n");
}

const SHIMS: Record<string, string> = {
  "next/link": path.join(shims, "link.tsx"),
  "next/navigation": path.join(shims, "navigation.ts"),
  "next/image": path.join(client, "image.tsx"),
  "next/dynamic": path.join(client, "dynamic.tsx"),
  "next/head": path.join(client, "nothing.tsx"),
  "next/script": path.join(client, "nothing.tsx"),
  "next/headers": path.join(client, "nothing.tsx"),
  "next/cache": path.join(client, "nothing.tsx"),
  "server-only": path.join(client, "nothing.tsx"),
  "client-only": path.join(client, "nothing.tsx"),
  "next/font/local": path.join(client, "font-local.ts"),
};

function aliases(): { from: RegExp; to: string }[] {
  const out: { from: RegExp; to: string }[] = [];
  const base = scanner.options.baseUrl ?? root;
  for (const [pattern, targets] of Object.entries(scanner.options.paths ?? {})) {
    const target = targets[0];
    if (!target) continue;
    const escaped = pattern.replace(/[.+?^${}()|[\]\\]/g, "\\$&").replace("*", "(.*)");
    out.push({ from: new RegExp(`^${escaped}$`), to: path.resolve(base, target).replace("*", "$1") });
  }
  return out;
}

function moodboard(): Plugin {
  const GOOGLE = "\0moodboard:google-fonts";
  const GLOBALS = "\0moodboard:globals";
  const NO_MOTION = "\0moodboard:no-motion";
  const paths = aliases();
  return {
    name: "moodboard",
    enforce: "pre",
    resolveId(source, importer, options) {
      const shim = SHIMS[source];
      if (shim) return shim;
      if (source === "next/font/google") return GOOGLE;
      if (source === "virtual:moodboard/globals") return GLOBALS;
      if (source === "motion" && importer?.endsWith("demos/tune.ts")) return NO_MOTION;
      if (source.endsWith("demos/resolve") && importer?.startsWith(stage)) return path.join(client, "resolve.ts");
      if (source.startsWith("/@moodboard/component")) return source;
      for (const { from, to } of paths) {
        if (from.test(source)) return this.resolve(source.replace(from, to), importer, { ...options, skipSelf: true });
      }
      return null;
    },
    load(id) {
      if (id === GOOGLE) return [`import { googleFont } from ${asModulePath(path.join(client, "font.ts"))};`, ...[...scanner.googleFonts].map((name) => `export const ${name} = googleFont(${JSON.stringify(name)});`)].join("\n");
      if (id === GLOBALS) return globalsModule();
      if (id === NO_MOTION) return "export const spring = () => { throw new Error('Springs are for the panel'); };";
      if (id.startsWith("/@moodboard/component")) {
        const component = byId().get(new URLSearchParams(id.split("?")[1]).get("id") ?? "");
        return component ? componentModule(component) : "export default function Missing() { return null; }";
      }
      return null;
    },
    configureServer(server) {
      server.middlewares.use(async (request, response, next) => {
        const url = new URL(request.url ?? "/", "http://local");
        const trusted = request.headers["x-moodboard"] === token;
        if (url.pathname === "/stage.html") {
          const page = `<!doctype html><html lang="en" data-project><head><meta charset="UTF-8" /><meta name="viewport" content="width=device-width, initial-scale=1" /><title>Stage</title><script>${PAGE_GUARD}window.process = { env: ${JSON.stringify(publicEnv())} };</script></head><body><div id="stage"></div><script type="module" src="/@fs${encodeURI(path.join(stage, "main.tsx"))}"></script></body></html>`;
          response.setHeader("Content-Type", "text/html");
          response.end(await server.transformIndexHtml(request.url ?? "/stage.html", page));
          return;
        }
        if (url.pathname === "/__moodboard/component") {
          const component = byId().get(url.searchParams.get("id") ?? "");
          if (!component) return json(response, null, 404);
          const sample = sampleOf(component);
          return json(response, { id: component.id, title: component.title, project: scanner.slug, folder: SAMPLE_FOLDER, props: sample.dials });
        }
        if (url.pathname === "/api/dials") {
          const saved = path.join(support, "dials", `${encodeURIComponent(url.searchParams.get("id") ?? "").replace(/[^A-Za-z0-9%_-]/g, (each) => `%${each.charCodeAt(0).toString(16).toUpperCase()}`)}.json`);
          response.setHeader("Content-Type", "application/json");
          response.end(fs.existsSync(saved) ? fs.readFileSync(saved) : "null");
          return;
        }
        if (url.pathname.startsWith("/cursors/")) {
          const file = path.join(here, "public", path.normalize(url.pathname));
          if (file.startsWith(path.join(here, "public")) && fs.existsSync(file)) {
            response.setHeader("Content-Type", "image/svg+xml");
            response.end(fs.readFileSync(file));
            return;
          }
        }
        if (url.pathname === "/__moodboard/dials") {
          if (!trusted) return json(response, { error: "No." }, 403);
          const component = byId().get(url.searchParams.get("id") ?? "");
          if (!component) return json(response, null, 404);
          const literals = literalsOf(component);
          known.set(component.id, new Map(literals.map((each) => [each.path, each.text])));
          const props = sampleOf(component).dials;
          return json(response, {
            id: component.id,
            title: component.title,
            file: component.file,
            exportName: component.exportName,
            root,
            project: scanner.slug,
            kind: "project",
            config: { ...(Object.keys(props).length > 0 ? { [SAMPLE_FOLDER]: props } : {}), ...dialConfig(literals) },
            values: Object.fromEntries(literals.map((each) => [each.path, each.dial.value])),
            files: [...new Set([component.file, ...literals.map((each) => path.relative(root, each.file))])],
            journal: journalNow(component),
          });
        }
        if (url.pathname === "/__moodboard/write" && request.method === "POST") {
          if (!trusted) return json(response, { error: "No." }, 403);
          const body = JSON.parse(await readBody(request)) as { id: string; values: Record<string, unknown> };
          const result = write(body.id, body.values);
          const component = byId().get(body.id);
          return json(response, { ...result, journal: component ? journalNow(component) : [] });
        }
        next();
      });
      const changed = (file: string) => {
        const relative = path.relative(root, file);
        if (relative.startsWith("..") || /(^|\/)(\.git|\.next|node_modules|out)\//.test(relative) || file.includes(".moodboard-")) return;
        fileChanged(file);
      };
      server.watcher.on("change", changed);
      server.watcher.on("add", changed);
      server.watcher.on("unlink", changed);
    },
  };
}

function publicEnv() {
  const env: Record<string, string> = { NODE_ENV: "development" };
  for (const name of [".env", ".env.development", ".env.local", ".env.development.local"]) {
    try {
      for (const entry of fs.readFileSync(path.join(root, name), "utf8").split("\n")) {
        const match = entry.match(/^\s*(NEXT_PUBLIC_[A-Z0-9_]+)\s*=\s*(.*)$/);
        if (match?.[1]) env[match[1]] = (match[2] ?? "").replace(/^["']|["']$/g, "");
      }
    } catch {}
  }
  return env;
}

const server = await createServer({
  configFile: false,
  root,
  appType: "custom",
  cacheDir: path.join(support, "vite", scanner.slug),
  publicDir: fs.existsSync(path.join(root, "public")) ? path.join(root, "public") : false,
  logLevel: "error",
  plugins: [moodboard(), react()],
  resolve: { dedupe: ["react", "react-dom"], preserveSymlinks: false },
  define: { "process.env.NODE_ENV": JSON.stringify("development") },
  optimizeDeps: { entries: [], include: ["react", "react-dom/client", "react/jsx-runtime", "react/jsx-dev-runtime"] },
  server: {
    host: "127.0.0.1",
    port: Number(argument("port") ?? 0),
    strictPort: false,
    hmr: { overlay: false },
    fs: { allow: [root, here, fs.realpathSync(path.join(root, "node_modules"))], deny: [".env", ".env.*", "*.{crt,pem}", "**/.git/**"] },
    watch: { ignored: ["**/.git/**", "**/.next/**", "**/node_modules/**", "**/out/**"] },
  },
});
await server.listen();
const address = server.httpServer?.address();
const port = typeof address === "object" && address ? address.port : 0;
say({ type: "listening", port, name: scanner.name, slug: scanner.slug, root });

// Building the type checker's view takes a moment, and everything after this is quick.
setTimeout(() => {
  samples.forExport("", "");
  publish([], false);
}, 0);

process.stdin.on("end", () => process.exit(0));
process.stdin.resume();
