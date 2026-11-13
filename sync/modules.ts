import path from "node:path";
import type { Scanner } from "./scan.ts";
import type { Found, Sample } from "./types.ts";

/** What the generated modules need to know about where things are. */
export type Places = {
  root: string;
  /** `src/stage` in the app's assets. */
  stage: string;
  /** `sync/client` in the app's assets. */
  client: string;
};

/** The panel's folder for props the wall made up, named so nobody takes them for the real data. */
export const SAMPLE_FOLDER = "Sample props";

const asModulePath = (file: string) => JSON.stringify(file);

/** Stands in for the Next.js modules a component can't use outside Next. */
export function shims({ stage, client }: Places): Record<string, string> {
  const nothing = path.join(client, "nothing.tsx");
  return {
    "next/link": path.join(stage, "shims", "link.tsx"),
    "next/navigation": path.join(stage, "shims", "navigation.ts"),
    "next/image": path.join(client, "image.tsx"),
    "next/dynamic": path.join(client, "dynamic.tsx"),
    "next/head": nothing,
    "next/script": nothing,
    "next/headers": nothing,
    "next/cache": nothing,
    "server-only": nothing,
    "client-only": nothing,
    "next/font/local": path.join(client, "font-local.ts"),
  };
}

/** The project's tsconfig `paths`, as patterns Vite can resolve. */
export function aliases(scanner: Scanner, root: string): { from: RegExp; to: string }[] {
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

/** The page module for one component: the project's providers around it, and its sample props with the panel's tune on top. */
export function componentModule(component: Found, scanner: Scanner, places: Places, sampleProps: Record<string, Sample>) {
  const { root, stage } = places;
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
const sample = revive(${JSON.stringify(sampleProps)});
export default function Demo() {
  const tuned = useTuned();
  return ${wrap(`createElement(Target, { ...sample, ...(tuned?.[${JSON.stringify(SAMPLE_FOLDER)}] ?? {}) })`)};
}`;
}

/** The project's global CSS, fonts and body class, as the root layout would set them. */
export function globalsModule(scanner: Scanner, { client }: Places) {
  const { css, bodyClass, fonts } = scanner.layout;
  const lines = [...css.map((each) => `import ${JSON.stringify(each)};`)];
  lines.push(`import { applyFont } from ${asModulePath(path.join(client, "font.ts"))};`);
  for (const font of fonts) lines.push(`applyFont(${JSON.stringify(font.family)}, ${JSON.stringify(font.source)}, ${font.options.includes("src:") ? "{}" : font.options});`);
  lines.push(`document.body.className = ${JSON.stringify(bodyClass)};`);
  return lines.join("\n");
}

/** The Google fonts the project imports, each as a stand-in that loads it. */
export function googleFontsModule(scanner: Scanner, { client }: Places) {
  return [`import { googleFont } from ${asModulePath(path.join(client, "font.ts"))};`, ...[...scanner.googleFonts].map((name) => `export const ${name} = googleFont(${JSON.stringify(name)});`)].join("\n");
}
