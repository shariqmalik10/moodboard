import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { afterAll, describe, expect, it } from "vitest";
import { readFile, Scanner } from "./scan.ts";

const exportsOf = (text: string, file = "/x/thing.tsx") => readFile(text, file).exports.map((each) => each.exportName);

describe("finding components in a file", () => {
  it("finds exported functions, arrows, memo and default exports that draw", () => {
    expect(exportsOf(`export function A() { return <div />; }`)).toEqual(["A"]);
    expect(exportsOf(`export const B = () => <div />;`)).toEqual(["B"]);
    expect(exportsOf(`export const C = memo(() => <div />);`)).toEqual(["C"]);
    expect(exportsOf(`export default function D() { return <div />; }`)).toEqual(["default"]);
  });

  it("skips helpers, async server components and what draws nothing", () => {
    expect(exportsOf(`export function useThing() { return <div />; }`)).toEqual([]);
    expect(exportsOf(`export async function Page() { return <div />; }`)).toEqual([]);
    expect(exportsOf(`export function Plain() { return 1; }`)).toEqual([]);
  });

  it("marks server-only files", () => {
    expect(readFile(`"use server";\nexport function A() { return <div />; }`, "/x/a.tsx").isServer).toBe(true);
    expect(readFile(`import "server-only";\nexport function A() { return <div />; }`, "/x/a.tsx").isServer).toBe(true);
  });
});

describe("scanning a project", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "moodboard-scan-"));
  const write = (file: string, text: string) => {
    fs.mkdirSync(path.dirname(path.join(root, file)), { recursive: true });
    fs.writeFileSync(path.join(root, file), text);
  };
  write("package.json", `{"name":"My App"}`);
  write("tsconfig.json", `{"compilerOptions":{"jsx":"preserve","baseUrl":".","paths":{"@/*":["./*"]}}}`);
  write("app/layout.tsx", `import "./globals.css";\nexport default function RootLayout({ children }) { return <html><body className="base">{children}</body></html>; }\n`);
  write("app/globals.css", `.base { color: red; }\n`);
  write("app/(app)/layout.tsx", `import { AppProvider } from "@/components/provider";\nexport default function L({ children }) { return <AppProvider now={new Date().toISOString()} secret={local}>{children}</AppProvider>; }\n`);
  write("app/page.tsx", `export default function Page() { return <div />; }\n`);
  write("components/provider.tsx", `export function AppProvider({ children }) { return <div>{children}</div>; }\n`);
  write("components/card.tsx", `import { Pip } from "./pip";\nexport function Card() { return <Pip />; }\n`);
  write("components/pip.tsx", `export function Pip() { return <i />; }\n`);
  write("components/card.test.tsx", `export function NotAComponent() { return <div />; }\n`);
  write("pages/old.tsx", `export default function Old() { return <div />; }\n`);
  write("src/pages/_app.tsx", `export default function App() { return <div />; }\n`);
  write("node_modules/x/index.tsx", `export function Nope() { return <div />; }\n`);
  afterAll(() => fs.rmSync(root, { recursive: true, force: true }));
  const scanner = new Scanner(root);
  scanner.scan();

  it("names the project and finds its components, not its pages, tests or packages", () => {
    expect(scanner.slug).toBe("my-app");
    expect(scanner.components().map((each) => each.exportName).sort()).toEqual(["Card", "Pip"]);
  });

  it("reads the layout's stylesheet and body class", () => {
    expect(scanner.layout.bodyClass).toBe("base");
    expect(scanner.layout.css).toEqual([path.join(root, "app/globals.css")]);
  });

  it("finds providers in nested layouts, keeping only props that mean the same outside the layout", () => {
    expect(scanner.layout.providers).toEqual([{ module: path.join(root, "components/provider.tsx"), exportName: "AppProvider", attributes: { now: "new Date().toISOString()" } }]);
  });

  it("changes a component's hash when something it imports changes, and leaves unrelated ones", () => {
    const hash = (name: string) => scanner.components().find((each) => each.exportName === name)?.hash;
    const provider = hash("AppProvider");
    const card = hash("Card");
    write("components/pip.tsx", `export function Pip() { return <b />; }\n`);
    scanner.fileChanged(path.join(root, "components/pip.tsx"));
    expect(hash("Card")).not.toBe(card);
    expect(hash("AppProvider")).toBe(provider);
  });

  it("changes every hash when the global CSS changes", () => {
    const before = scanner.components().map((each) => each.hash);
    write("app/globals.css", `.base { color: blue; }\n`);
    scanner.fileChanged(path.join(root, "app/globals.css"));
    const after = scanner.components().map((each) => each.hash);
    after.forEach((hash, at) => expect(hash).not.toBe(before[at]));
  });
});

describe("scanning a project written in JavaScript", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "moodboard-scan-js-"));
  const write = (file: string, text: string) => {
    fs.mkdirSync(path.dirname(path.join(root, file)), { recursive: true });
    fs.writeFileSync(path.join(root, file), text);
  };
  write("package.json", `{"name":"plain"}`);
  write("jsconfig.json", `{"compilerOptions":{"paths":{"@/*":["./src/*"]}}}`);
  write("src/app/layout.js", `import "./globals.css";\nimport { GardenProvider } from "@/app/providers";\nexport default function RootLayout({ children }) { return <html><body className="base"><GardenProvider>{children}</GardenProvider></body></html>; }\n`);
  write("src/app/globals.css", `.base { color: red; }\n`);
  write("src/app/page.js", `export default function Page() { return <div />; }\n`);
  write("src/app/providers.js", `export function GardenProvider({ children }) { return <div>{children}</div>; }\n`);
  write("src/components/Card.js", `import { Pip } from "@/components/Pip";\nexport function Card() { return <Pip />; }\n`);
  write("src/components/Pip.jsx", `export default function Pip() { return <i />; }\n`);
  write("next.config.js", `module.exports = {};\n`);
  afterAll(() => fs.rmSync(root, { recursive: true, force: true }));
  const scanner = new Scanner(root);
  scanner.scan();

  it("finds components in .js and .jsx files, and leaves out pages", () => {
    expect(scanner.components().map((each) => [each.id, each.file])).toEqual([
      ["project/plain/src/components/Card/Card", "src/components/Card.js"],
      ["project/plain/src/components/Pip/default", "src/components/Pip.jsx"],
    ]);
  });

  it("reads the layout and its providers through jsconfig's paths", () => {
    expect(scanner.layout.css).toEqual([path.join(root, "src/app/globals.css")]);
    expect(scanner.layout.providers.map((each) => each.module)).toEqual([path.join(root, "src/app/providers.js")]);
  });
});
