import { createHash } from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import ts from "typescript";
import type { Found } from "./types.ts";

const SKIPPED_FOLDERS = new Set(["node_modules", ".next", "out", "dist", "build", "public", "coverage", "scripts", "workers", "extension", "supabase", "db", "docs", "design", "research"]);
/** A file that can hold a component. Next.js lets `.js` files hold JSX, and its JavaScript template writes them. */
const COMPONENT_FILE = /\.(tsx|jsx|js)$/;
const SOURCE_FILE = /\.[jt]sx?$/;
const NOT_COMPONENTS = /(^|\/)(page|layout|loading|error|global-error|not-found|template|default|route|opengraph-image|twitter-image|icon|apple-icon|middleware|proxy)\.(tsx|jsx|js)$/;
const TEST_OR_DEMO = /\.(test|spec|stories|moodboard)\.(tsx|jsx|js)$/;
const isLayout = (file: string) => /^layout\.(tsx|jsx|js)$/.test(path.basename(file));
const SERVER_ONLY = new Set(["next/headers", "server-only"]);

export type Layout = {
  /** Absolute paths or package names, in the order the layout imports them. */
  css: string[];
  bodyClass: string;
  fonts: { family: string; options: string; source: "google" | "local" }[];
  /** Context the app's layouts wrap every page in, outermost first. Components that read them throw without them. */
  providers: Provider[];
};

/** `attributes` holds each prop's source expression. */
export type Provider = { module: string; exportName: string; attributes: Record<string, string> };

/** An expression that means the same outside the layout it was written in, such as `new Date().toISOString()`. */
function needsNoScope(node: ts.Node): boolean {
  if (ts.isIdentifier(node) && !(ts.isPropertyAccessExpression(node.parent) && node.parent.name === node)) return ["Date", "Math", "JSON", "undefined"].includes(node.text);
  return !ts.forEachChild(node, (child) => !needsNoScope(child) || undefined);
}

type FileFacts = {
  text: string;
  imports: string[];
  exports: { name: string; exportName: string }[];
  isServer: boolean;
};

const words = (name: string) => {
  const spaced = name.replace(/([a-z0-9])([A-Z])/g, "$1 $2").replace(/([A-Z])([A-Z][a-z])/g, "$1 $2");
  return spaced.charAt(0).toUpperCase() + spaced.slice(1).toLowerCase();
};

const slug = (text: string) => text.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");

const hasJsx = (node: ts.Node): boolean => {
  if (ts.isJsxElement(node) || ts.isJsxSelfClosingElement(node) || ts.isJsxFragment(node)) return true;
  return Boolean(ts.forEachChild(node, (child) => hasJsx(child) || undefined));
};

const isAsync = (node: ts.Node) => ts.canHaveModifiers(node) && Boolean(ts.getModifiers(node)?.some((each) => each.kind === ts.SyntaxKind.AsyncKeyword));

/** A function that draws something, or `memo(...)` and `forwardRef(...)` around one. */
function drawsJsx(node: ts.Node | undefined): boolean {
  if (!node) return false;
  if (ts.isFunctionDeclaration(node) || ts.isFunctionExpression(node) || ts.isArrowFunction(node)) return !isAsync(node) && hasJsx(node);
  if (ts.isCallExpression(node)) return node.arguments.some(drawsJsx);
  return false;
}

const isExported = (node: ts.Node) => ts.canHaveModifiers(node) && Boolean(ts.getModifiers(node)?.some((each) => each.kind === ts.SyntaxKind.ExportKeyword));
const isDefault = (node: ts.Node) => ts.canHaveModifiers(node) && Boolean(ts.getModifiers(node)?.some((each) => each.kind === ts.SyntaxKind.DefaultKeyword));
const named = (name: string) => /^[A-Z]/.test(name);

export function readFile(text: string, file: string): FileFacts {
  const source = ts.createSourceFile(file, text, ts.ScriptTarget.Latest, true, /\.jsx?$/.test(file) ? ts.ScriptKind.JSX : ts.ScriptKind.TSX);
  const imports: string[] = [];
  const exports: FileFacts["exports"] = [];
  const local = new Map<string, ts.Node>();
  let isServer = false;
  for (const statement of source.statements) {
    if (ts.isExpressionStatement(statement) && ts.isStringLiteral(statement.expression) && statement.expression.text === "use server") isServer = true;
    if (ts.isImportDeclaration(statement) && ts.isStringLiteral(statement.moduleSpecifier)) {
      imports.push(statement.moduleSpecifier.text);
      if (SERVER_ONLY.has(statement.moduleSpecifier.text)) isServer = true;
    }
    if (ts.isExportDeclaration(statement) && statement.moduleSpecifier && ts.isStringLiteral(statement.moduleSpecifier)) imports.push(statement.moduleSpecifier.text);
    if (ts.isFunctionDeclaration(statement) && statement.name) {
      local.set(statement.name.text, statement);
      if (isExported(statement) && named(statement.name.text) && drawsJsx(statement)) exports.push({ name: statement.name.text, exportName: isDefault(statement) ? "default" : statement.name.text });
    }
    if (ts.isFunctionDeclaration(statement) && !statement.name && isDefault(statement) && drawsJsx(statement)) {
      const base = path.parse(file).name;
      exports.push({ name: base.charAt(0).toUpperCase() + base.slice(1), exportName: "default" });
    }
    if (ts.isVariableStatement(statement)) {
      for (const each of statement.declarationList.declarations) {
        if (!ts.isIdentifier(each.name)) continue;
        if (each.initializer) local.set(each.name.text, each.initializer);
        if (isExported(statement) && named(each.name.text) && drawsJsx(each.initializer)) exports.push({ name: each.name.text, exportName: each.name.text });
      }
    }
    if (ts.isExportAssignment(statement) && !statement.isExportEquals) {
      const target = ts.isIdentifier(statement.expression) ? statement.expression.text : null;
      if (target && named(target) && drawsJsx(local.get(target))) exports.push({ name: target, exportName: "default" });
      else if (!target && drawsJsx(statement.expression)) {
        const base = path.parse(file).name;
        exports.push({ name: base.charAt(0).toUpperCase() + base.slice(1), exportName: "default" });
      }
    }
    if (ts.isExportDeclaration(statement) && !statement.moduleSpecifier && statement.exportClause && ts.isNamedExports(statement.exportClause)) {
      for (const each of statement.exportClause.elements) {
        const name = (each.propertyName ?? each.name).text;
        if (named(name) && drawsJsx(local.get(name))) exports.push({ name, exportName: each.name.text });
      }
    }
  }
  return { text, imports, exports, isServer };
}

export class Scanner {
  readonly slug: string;
  readonly name: string;
  readonly options: ts.CompilerOptions;
  private facts = new Map<string, FileFacts>();
  private moduleHost: ts.ModuleResolutionHost = { fileExists: ts.sys.fileExists, readFile: ts.sys.readFile, directoryExists: ts.sys.directoryExists, realpath: ts.sys.realpath, getCurrentDirectory: () => process.cwd() };
  private resolved = new Map<string, string | null>();
  private cssTexts = new Map<string, string>();
  layout: Layout = { css: [], bodyClass: "", fonts: [], providers: [] };
  /** Names imported from `next/font/google` anywhere, since the shim has to export each of them. */
  googleFonts = new Set<string>();

  readonly root: string;

  constructor(root: string, slugOverride?: string) {
    this.root = root;
    const config = ts.findConfigFile(root, ts.sys.fileExists, "tsconfig.json") ?? ts.findConfigFile(root, ts.sys.fileExists, "jsconfig.json");
    const parsed = config ? ts.parseJsonConfigFileContent(ts.readConfigFile(config, ts.sys.readFile).config, ts.sys, path.dirname(config)) : null;
    this.options = { ...parsed?.options, allowJs: true, jsx: ts.JsxEmit.Preserve, noEmit: true, skipLibCheck: true, incremental: false, composite: false, tsBuildInfoFile: undefined };
    let name = path.basename(root);
    try {
      name = (JSON.parse(fs.readFileSync(path.join(root, "package.json"), "utf8")) as { name?: string }).name ?? name;
    } catch {}
    this.name = name;
    this.slug = slugOverride ?? (slug(name) || "project");
  }

  /** Every source file worth reading, from the project root down. */
  private walk(folder: string, out: string[] = []) {
    for (const entry of fs.readdirSync(folder, { withFileTypes: true })) {
      if (entry.name.startsWith(".") || SKIPPED_FOLDERS.has(entry.name)) continue;
      const full = path.join(folder, entry.name);
      if (entry.isDirectory()) this.walk(full, out);
      else if (SOURCE_FILE.test(entry.name) && !entry.name.endsWith(".d.ts")) out.push(full);
    }
    return out;
  }

  scan() {
    this.facts.clear();
    this.resolved.clear();
    this.cssTexts.clear();
    for (const file of this.walk(this.root)) this.readInto(file);
    this.readLayout();
  }

  private readInto(file: string) {
    try {
      this.facts.set(file, readFile(fs.readFileSync(file, "utf8"), file));
    } catch {
      this.facts.delete(file);
    }
  }

  /** Reads one file again. Says whether the set of known modules or the global CSS could have changed. */
  fileChanged(file: string) {
    this.resolved.clear();
    if (file.endsWith(".css")) {
      this.cssTexts.delete(file);
      return;
    }
    if (!SOURCE_FILE.test(file) || file.endsWith(".d.ts")) return;
    const relative = path.relative(this.root, file);
    if (relative.split(path.sep).some((part) => part.startsWith(".") || SKIPPED_FOLDERS.has(part))) return;
    this.readInto(file);
    if (isLayout(file)) this.readLayout();
  }

  /** Every `*Provider` that wraps `{children}` in a layout, shallowest layout first. */
  private readProviders(): Provider[] {
    const layouts = [...this.facts.keys()].filter(isLayout).sort((a, b) => a.split(path.sep).length - b.split(path.sep).length);
    const out = new Map<string, Provider>();
    for (const file of layouts) {
      const source = ts.createSourceFile(file, this.facts.get(file)?.text ?? "", ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);
      const imported = new Map<string, { module: string; exportName: string }>();
      for (const statement of source.statements) {
        if (!ts.isImportDeclaration(statement) || !ts.isStringLiteral(statement.moduleSpecifier) || !statement.importClause) continue;
        const specifier = statement.moduleSpecifier.text;
        const module = this.resolve(specifier, file) ?? specifier;
        if (statement.importClause.name) imported.set(statement.importClause.name.text, { module, exportName: "default" });
        const bindings = statement.importClause.namedBindings;
        if (bindings && ts.isNamedImports(bindings)) for (const each of bindings.elements) imported.set(each.name.text, { module, exportName: (each.propertyName ?? each.name).text });
      }
      const wrapsChildren = (node: ts.Node): boolean => (ts.isJsxExpression(node) && node.expression?.getText(source) === "children") || Boolean(ts.forEachChild(node, (child) => wrapsChildren(child) || undefined));
      const visit = (node: ts.Node) => {
        if (ts.isJsxElement(node) && wrapsChildren(node)) {
          const name = node.openingElement.tagName.getText(source);
          const from = imported.get(name);
          if (from && /Provider$/.test(name)) {
            const attributes: Record<string, string> = {};
            for (const attribute of node.openingElement.attributes.properties) {
              if (!ts.isJsxAttribute(attribute) || !attribute.initializer) continue;
              if (ts.isStringLiteral(attribute.initializer)) attributes[attribute.name.getText(source)] = JSON.stringify(attribute.initializer.text);
              else if (ts.isJsxExpression(attribute.initializer) && attribute.initializer.expression && needsNoScope(attribute.initializer.expression)) attributes[attribute.name.getText(source)] = attribute.initializer.expression.getText(source);
            }
            out.set(`${from.module}#${from.exportName}`, { ...from, attributes });
          }
        }
        ts.forEachChild(node, visit);
      };
      visit(source);
    }
    return [...out.values()];
  }

  private readLayout() {
    const file = ["src/app", "app"].flatMap((folder) => ["tsx", "jsx", "js"].map((extension) => path.join(this.root, folder, `layout.${extension}`))).find((each) => fs.existsSync(each));
    this.googleFonts.clear();
    for (const facts of this.facts.values()) {
      if (!facts.imports.includes("next/font/google")) continue;
      for (const match of facts.text.matchAll(/import\s*\{([^}]*)\}\s*from\s*["']next\/font\/google["']/g)) {
        for (const each of (match[1] ?? "").split(",")) {
          const name = each.split(" as ")[0]?.trim();
          if (name) this.googleFonts.add(name);
        }
      }
    }
    const layout: Layout = { css: [], bodyClass: "", fonts: [], providers: this.readProviders() };
    if (!file) {
      this.layout = layout;
      return;
    }
    const source = ts.createSourceFile(file, fs.readFileSync(file, "utf8"), ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);
    const fontNames = new Map<string, "google" | "local">();
    for (const statement of source.statements) {
      if (!ts.isImportDeclaration(statement) || !ts.isStringLiteral(statement.moduleSpecifier)) continue;
      const from = statement.moduleSpecifier.text;
      if (from.endsWith(".css")) layout.css.push(from.startsWith(".") ? path.resolve(path.dirname(file), from) : from);
      if (from === "next/font/google" && statement.importClause?.namedBindings && ts.isNamedImports(statement.importClause.namedBindings)) {
        for (const each of statement.importClause.namedBindings.elements) fontNames.set(each.name.text, "google");
      }
      if (from === "next/font/local" && statement.importClause?.name) fontNames.set(statement.importClause.name.text, "local");
    }
    const visit = (node: ts.Node) => {
      if (ts.isCallExpression(node) && ts.isIdentifier(node.expression) && fontNames.has(node.expression.text) && node.arguments[0]) {
        layout.fonts.push({ family: node.expression.text, options: node.arguments[0].getText(source), source: fontNames.get(node.expression.text) ?? "google" });
      }
      if (ts.isJsxOpeningElement(node) && node.tagName.getText(source) === "body") {
        for (const attribute of node.attributes.properties) {
          if (ts.isJsxAttribute(attribute) && attribute.name.getText(source) === "className" && attribute.initializer && ts.isStringLiteral(attribute.initializer)) layout.bodyClass = attribute.initializer.text;
        }
      }
      ts.forEachChild(node, visit);
    };
    visit(source);
    this.layout = layout;
  }

  /** The file a module specifier lands on, if it's inside the project. */
  private resolve(specifier: string, from: string): string | null {
    const key = `${from}\n${specifier}`;
    const known = this.resolved.get(key);
    if (known !== undefined) return known;
    let out: string | null = null;
    if (specifier.endsWith(".css")) {
      const relative = specifier.startsWith(".") ? path.resolve(path.dirname(from), specifier) : null;
      out = relative && fs.existsSync(relative) ? relative : null;
    } else {
      const found = ts.resolveModuleName(specifier, from, this.options, this.moduleHost).resolvedModule?.resolvedFileName;
      out = found && !found.includes("node_modules") && found.startsWith(this.root) ? found : null;
    }
    this.resolved.set(key, out);
    return out;
  }

  private cssText(file: string, seen = new Set<string>()): string {
    if (seen.has(file)) return "";
    seen.add(file);
    let text = this.cssTexts.get(file);
    if (text === undefined) {
      try {
        text = fs.readFileSync(file, "utf8");
      } catch {
        text = "";
      }
      this.cssTexts.set(file, text);
    }
    let out = text;
    for (const match of text.matchAll(/@import\s+["']([^"']+\.css)["']/g)) {
      const next = match[1]?.startsWith(".") ? path.resolve(path.dirname(file), match[1]) : null;
      if (next) out += this.cssText(next, seen);
    }
    return out;
  }

  /** Every stylesheet the root layout reaches, so a dial can find a component's CSS rules. */
  globalCssFiles(): string[] {
    const out = new Set<string>();
    const add = (file: string) => {
      if (out.has(file) || !fs.existsSync(file)) return;
      out.add(file);
      for (const match of (this.cssTexts.get(file) ?? fs.readFileSync(file, "utf8")).matchAll(/@import\s+["']([^"']+\.css)["']/g)) {
        if (match[1]?.startsWith(".")) add(path.resolve(path.dirname(file), match[1]));
      }
    };
    for (const each of this.layout.css) if (path.isAbsolute(each)) add(each);
    return [...out];
  }

  importedCss(file: string): string[] {
    const facts = this.facts.get(file);
    if (!facts) return [];
    return facts.imports.filter((each) => each.endsWith(".css")).map((each) => this.resolve(each, file)).filter((each): each is string => each !== null);
  }

  private hashOf(file: string) {
    const hash = createHash("sha1");
    const seen = new Set<string>();
    const visit = (at: string) => {
      if (seen.has(at)) return;
      seen.add(at);
      if (at.endsWith(".css")) return void hash.update(this.cssText(at));
      const facts = this.facts.get(at);
      if (!facts) return;
      hash.update(facts.text);
      for (const each of facts.imports) {
        const next = this.resolve(each, at);
        if (next) visit(next);
      }
    };
    visit(file);
    for (const each of this.layout.css) if (path.isAbsolute(each)) visit(each);
    for (const each of this.layout.providers) if (path.isAbsolute(each.module)) visit(each.module);
    hash.update(JSON.stringify(this.layout.fonts));
    return hash.digest("hex").slice(0, 16);
  }

  components(): Found[] {
    const out: Found[] = [];
    const hashes = new Map<string, string>();
    // A provider already wraps every tile, and alone it only draws its sample children.
    const wrapping = new Set(this.layout.providers.map((each) => `${each.module}#${each.exportName}`));
    for (const [file, facts] of this.facts) {
      const relative = path.relative(this.root, file).split(path.sep).join("/");
      if (!COMPONENT_FILE.test(file) || NOT_COMPONENTS.test(relative) || TEST_OR_DEMO.test(relative) || /^(src\/)?pages\//.test(relative) || facts.isServer || facts.exports.length === 0) continue;
      const seen = new Set<string>();
      for (const each of facts.exports) {
        if (seen.has(each.exportName) || wrapping.has(`${file}#${each.exportName}`)) continue;
        seen.add(each.exportName);
        let hash = hashes.get(file);
        if (!hash) {
          hash = this.hashOf(file);
          hashes.set(file, hash);
        }
        const sidecar = file.replace(COMPONENT_FILE, ".moodboard.$1");
        out.push({ id: `project/${this.slug}/${relative.replace(COMPONENT_FILE, "")}/${each.exportName}`, title: words(each.name), file: relative, exportName: each.exportName, hash, sidecar: fs.existsSync(sidecar) ? path.relative(this.root, sidecar) : undefined });
      }
    }
    return out.sort((a, b) => a.id.localeCompare(b.id));
  }

  sourceFiles() {
    return [...this.facts.keys()];
  }
}
