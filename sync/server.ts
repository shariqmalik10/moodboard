import { randomBytes } from "node:crypto";
import fs from "node:fs";
import type { IncomingMessage, ServerResponse } from "node:http";
import path from "node:path";
import react from "@vitejs/plugin-react";
import { createServer, loadEnv, transformWithEsbuild, type Plugin, type ViteDevServer } from "vite";
import { dialConfig, readComponent, readCss } from "./literals.ts";
import { aliases, componentModule, globalsModule, googleFontsModule, type Places, SAMPLE_FOLDER, shims } from "./modules.ts";
import { Samples } from "./samples.ts";
import { Scanner } from "./scan.ts";
import type { Found, Literal, Sample } from "./types.ts";
import { DialWriter } from "./writer.ts";

const argument = (name: string) => {
  const at = process.argv.indexOf(`--${name}`);
  return at >= 0 ? process.argv[at + 1] : undefined;
};

const root = path.resolve(argument("root") ?? process.cwd());
const support = path.resolve(argument("support") ?? path.join(root, ".moodboard"));
const here = path.resolve(argument("assets") ?? path.join(import.meta.dirname, ".."));
const token = argument("token") ?? process.env.MOODBOARD_TOKEN ?? randomBytes(16).toString("hex");
const stage = path.join(here, "src/stage");
const places: Places = { root, stage, client: path.join(here, "sync/client") };

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
  HTMLFormElement.prototype.submit = () => {};
  const sendSocket = WebSocket.prototype.send;
  WebSocket.prototype.send = function (data) { if (new URL(this.url).host === location.host) sendSocket.call(this, data); };
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

/** Every node_modules Node would look in from the project, since a monorepo keeps its packages in the root's. */
function installedPackages(from: string): string[] {
  const found: string[] = [];
  for (let folder = from; ; folder = path.dirname(folder)) {
    const packages = path.join(folder, "node_modules");
    if (fs.existsSync(packages)) found.push(fs.realpathSync(packages));
    if (path.dirname(folder) === folder) return found;
  }
}

const scanner = new Scanner(root, argument("slug"));
scanner.scan();
const samples = new Samples(root, scanner.options, () => scanner.sourceFiles());
let found = new Map<string, Found>();
const componentFor = (url: URL) => found.get(url.searchParams.get("id") ?? "");

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

const writer = new DialWriter(root, literalsOf);

type Made = { props: Record<string, Sample>; dials: Record<string, unknown> };
const sampleCache = new Map<string, Made & { hash: string }>();
function sampleOf(component: Found) {
  const cached = sampleCache.get(component.id);
  if (cached?.hash === component.hash) return cached;
  let made: Made = { props: {}, dials: {} };
  try {
    made = samples.forExport(path.join(root, component.file), component.exportName);
  } catch (reason) {
    say({ type: "log", message: `Sample props for ${component.id}: ${String(reason)}` });
  }
  const entry = { hash: component.hash, ...made };
  sampleCache.set(component.id, entry);
  return entry;
}

const COMPONENT_MODULE = "/@moodboard/component";
const componentIdOf = (moduleId: string) => new URLSearchParams(moduleId.split("?")[1]).get("id") ?? "";

/** Tells the app which components exist, and drops the cached modules of any whose source changed. */
function publish(server: ViteDevServer, files: string[], bySelf: boolean) {
  const next = scanner.components();
  found = new Map(next.map((each) => [each.id, each]));
  const changed = new Set(next.filter((each) => sampleCache.has(each.id) && sampleCache.get(each.id)?.hash !== each.hash).map((each) => each.id));
  for (const module of server.moduleGraph.idToModuleMap.values()) {
    if (module.id?.startsWith(COMPONENT_MODULE) && changed.has(componentIdOf(module.id))) server.moduleGraph.invalidateModule(module);
  }
  say({ type: "components", name: scanner.name, slug: scanner.slug, items: next, files: files.map((each) => path.relative(root, each)), bySelf });
}

/** Gathers a burst of saves into one publish, and says whether every file in it was a write of our own. */
function watchSaves(server: ViteDevServer) {
  let pending = new Set<string>();
  let timer: NodeJS.Timeout | undefined;
  return (file: string) => {
    scanner.fileChanged(file);
    samples.touched(file);
    pending.add(file);
    clearTimeout(timer);
    timer = setTimeout(() => {
      const files = [...pending];
      pending = new Set();
      publish(server, files, writer.wroteAll(files));
    }, 30);
  };
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

/** One address the server answers itself. `trusted` ones answer only the app, which sends the token. */
type Route = { trusted?: boolean; method?: string; answer: (url: URL, request: IncomingMessage, response: ServerResponse) => unknown };

/** A request that fails answers with why, so the app can say so, instead of ending the server for every tile. */
const answering =
  (handle: (request: IncomingMessage, response: ServerResponse, next: () => void) => Promise<void>) =>
  (request: IncomingMessage, response: ServerResponse, next: () => void) =>
    handle(request, response, next).catch((reason: NodeJS.ErrnoException) => {
      const refused = reason.code === "EPERM" || reason.code === "EACCES";
      json(response, { error: refused ? "Moodboard isn't allowed to change it. Check that you can write to its folder, or, if macOS asked, turn Moodboard on in System Settings, under Privacy & Security, Files and Folders." : reason.message }, 500);
    });

function routes(server: ViteDevServer): Record<string, Route> {
  return {
    "/stage.html": {
      async answer(_url, request, response) {
        const page = `<!doctype html><html lang="en" data-project><head><meta charset="UTF-8" /><meta name="viewport" content="width=device-width, initial-scale=1" /><title>Stage</title><script>${PAGE_GUARD}window.process = { env: ${JSON.stringify(publicEnv())} };</script></head><body><div id="stage"></div><script type="module" src="/@fs${encodeURI(path.join(stage, "main.tsx"))}"></script></body></html>`;
        response.setHeader("Content-Type", "text/html");
        response.end(await server.transformIndexHtml(request.url ?? "/stage.html", page));
      },
    },
    "/__moodboard/component": {
      answer(url, _request, response) {
        const component = componentFor(url);
        if (!component) return json(response, null, 404);
        return json(response, { id: component.id, title: component.title, project: scanner.slug, folder: SAMPLE_FOLDER, props: sampleOf(component).dials });
      },
    },
    "/api/dials": {
      // Named the way the app names its saved dials in Application Support.
      answer(url, _request, response) {
        const name = encodeURIComponent(url.searchParams.get("id") ?? "").replace(/[^A-Za-z0-9%_-]/g, (each) => `%${each.charCodeAt(0).toString(16).toUpperCase()}`);
        const saved = path.join(support, "dials", `${name}.json`);
        response.setHeader("Content-Type", "application/json");
        response.end(fs.existsSync(saved) ? fs.readFileSync(saved) : "null");
      },
    },
    "/__moodboard/dials": {
      trusted: true,
      answer(url, _request, response) {
        const component = componentFor(url);
        if (!component) return json(response, null, 404);
        const literals = literalsOf(component);
        writer.show(component, literals);
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
          journal: writer.journalNow(component),
        });
      },
    },
    "/__moodboard/write": {
      trusted: true,
      method: "POST",
      async answer(_url, request, response) {
        const body = JSON.parse(await readBody(request)) as { id: string; values: Record<string, unknown> };
        const component = found.get(body.id);
        const result = writer.write(component, body.values);
        return json(response, { ...result, journal: component ? writer.journalNow(component) : [] });
      },
    },
  };
}

/** The wall's cursor pictures, from the app's own public folder. */
function cursor(url: URL, response: ServerResponse) {
  const folder = path.join(here, "public");
  const file = path.join(folder, path.normalize(url.pathname));
  if (!url.pathname.startsWith("/cursors/") || !file.startsWith(folder) || !fs.existsSync(file)) return false;
  response.setHeader("Content-Type", "image/svg+xml");
  response.end(fs.readFileSync(file));
  return true;
}

function moodboard(): Plugin {
  const GOOGLE = "\0moodboard:google-fonts";
  const GLOBALS = "\0moodboard:globals";
  const NO_MOTION = "\0moodboard:no-motion";
  const replacements = shims(places);
  const paths = aliases(scanner, root);
  return {
    name: "moodboard",
    enforce: "pre",
    resolveId(source, importer, options) {
      const shim = replacements[source];
      if (shim) return shim;
      if (source === "next/font/google") return GOOGLE;
      if (source === "virtual:moodboard/globals") return GLOBALS;
      if (source === "motion" && importer?.endsWith("demos/tune.ts")) return NO_MOTION;
      if (source.endsWith("demos/resolve") && importer?.startsWith(stage)) return path.join(places.client, "resolve.ts");
      if (source.startsWith(COMPONENT_MODULE)) return source;
      for (const { from, to } of paths) {
        if (from.test(source)) return this.resolve(source.replace(from, to), importer, { ...options, skipSelf: true });
      }
      return null;
    },
    load(id) {
      if (id === GOOGLE) return googleFontsModule(scanner, places);
      if (id === GLOBALS) return globalsModule(scanner, places);
      if (id === NO_MOTION) return "export const spring = () => { throw new Error('Springs are for the panel'); };";
      if (id.startsWith(COMPONENT_MODULE)) {
        const component = found.get(componentIdOf(id));
        return component ? componentModule(component, scanner, places, sampleOf(component).props) : "export default function Missing() { return null; }";
      }
      return null;
    },
    transform(code, id) {
      // Vite reads JSX only in .jsx and .tsx files, and Next.js projects written in JavaScript keep it in .js files.
      if (!id.endsWith(".js") || !id.startsWith(root) || id.includes("/node_modules/") || !code.includes("<")) return null;
      return transformWithEsbuild(code, id, { loader: "jsx", jsx: "automatic" });
    },
    configureServer(server) {
      const table = routes(server);
      server.middlewares.use(answering(async (request, response, next) => {
        const url = new URL(request.url ?? "/", "http://local");
        const route = table[url.pathname];
        if (route && (!route.method || route.method === request.method)) {
          if (route.trusted && request.headers["x-moodboard"] !== token) return json(response, { error: "No." }, 403);
          await route.answer(url, request, response);
          return;
        }
        if (cursor(url, response)) return;
        next();
      }));
      const saved = watchSaves(server);
      const changed = (file: string) => {
        const relative = path.relative(root, file);
        if (relative.startsWith("..") || /(^|\/)(\.git|\.next|node_modules|out)\//.test(relative) || file.includes(".moodboard-")) return;
        saved(file);
      };
      server.watcher.on("change", changed);
      server.watcher.on("add", changed);
      server.watcher.on("unlink", changed);
    },
  };
}

/** The same files Next.js reads in development, with the same comments, quotes and `${NAME}` expansion. */
const publicEnv = () => ({ NODE_ENV: "development", ...loadEnv("development", root, "NEXT_PUBLIC_") });

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
    fs: { allow: [root, here, ...installedPackages(root)], deny: [".env", ".env.*", "*.{crt,pem}", "**/.git/**"] },
    watch: { ignored: ["**/.git/**", "**/.next/**", "**/node_modules/**", "**/out/**"] },
  },
});
await server.listen();
const address = server.httpServer?.address();
const port = typeof address === "object" && address ? address.port : 0;
say({ type: "listening", port, name: scanner.name, slug: scanner.slug, root });

// Building the type checker's view takes a moment, and everything after this is quick.
setTimeout(() => {
  samples.warm();
  publish(server, [], false);
}, 0);

process.stdin.on("end", () => process.exit(0));
process.stdin.resume();
