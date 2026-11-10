import fs from "node:fs";
import ts from "typescript";
import type { Sample } from "./types.ts";

/** A small grey picture for any prop that wants one. */
const PICTURE = "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='480' height='640'%3E%3Crect width='480' height='640' fill='%23d9d5cb'/%3E%3C/svg%3E";
/** A dialog or sheet that starts shut draws nothing to look at. */
const STARTS_OPEN = /^(is)?(open|visible|shown|expanded)$/i;
const SKIPPED_PROPS = new Set(["className", "style", "ref", "key", "id", "as", "asChild"]);

function hinted(name: string, order: number): string {
  const lower = name.toLowerCase();
  if (/(^|_)(src|image|img|photo|poster|cover|avatar|thumbnail|picture)/.test(lower) || /(image|photo|poster|cover|avatar|thumbnail|src|picture)(url)?$/.test(lower)) return PICTURE;
  if (/href|url|link/.test(lower)) return "#";
  if (/email/.test(lower)) return "ada@example.com";
  if (/date|time|at$/.test(lower)) return new Date(Date.UTC(2026, 5, 1 + order)).toISOString();
  if (/^id$|id$/.test(name)) return `sample-${order + 1}`;
  if (/color|colour/.test(lower)) return "#6b7280";
  const spaced = name.replace(/([a-z0-9])([A-Z])/g, "$1 $2").toLowerCase();
  const first = spaced.charAt(0).toUpperCase() + spaced.slice(1);
  return order > 0 ? `${first} ${order + 1}` : first;
}

function hintedNumber(name: string, order: number): number {
  const lower = name.toLowerCase();
  if (/index|rotate|angle|offset/.test(lower)) return order;
  if (/total|count|max|length/.test(lower)) return 3;
  if (/progress|ratio|percent|affinity|opacity/.test(lower)) return lower.includes("percent") ? 50 : 0.5;
  if (/year/.test(lower)) return 2026;
  return order + 1;
}

export class Samples {
  private versions = new Map<string, number>();
  private service: ts.LanguageService;

  constructor(root: string, options: ts.CompilerOptions, files: () => string[]) {
    const host: ts.LanguageServiceHost = {
      getCompilationSettings: () => options,
      getScriptFileNames: files,
      getScriptVersion: (file) => String(this.versions.get(file) ?? 0),
      getScriptSnapshot: (file) => (fs.existsSync(file) ? ts.ScriptSnapshot.fromString(fs.readFileSync(file, "utf8")) : undefined),
      getCurrentDirectory: () => root,
      getDefaultLibFileName: ts.getDefaultLibFilePath,
      fileExists: ts.sys.fileExists,
      readFile: ts.sys.readFile,
      readDirectory: ts.sys.readDirectory,
      directoryExists: ts.sys.directoryExists,
      getDirectories: ts.sys.getDirectories,
    };
    this.service = ts.createLanguageService(host);
  }

  /** Builds the type checker's view of the project now, so the first component asked for doesn't wait on it. */
  warm() {
    this.service.getProgram();
  }

  touched(file: string) {
    this.versions.set(file, (this.versions.get(file) ?? 0) + 1);
  }

  /** Sample props for one exported component, plus which of them make sense as dials. */
  forExport(file: string, exportName: string): { props: Record<string, Sample>; dials: Record<string, unknown> } {
    const program = this.service.getProgram();
    const source = program?.getSourceFile(file);
    if (!program || !source) return { props: {}, dials: {} };
    const checker = program.getTypeChecker();
    const module = checker.getSymbolAtLocation(source);
    const symbol = module && checker.getExportsOfModule(module).find((each) => each.name === exportName);
    if (!symbol) return { props: {}, dials: {} };
    const resolved = symbol.flags & ts.SymbolFlags.Alias ? checker.getAliasedSymbol(symbol) : symbol;
    const type = checker.getTypeOfSymbolAtLocation(resolved, source);
    const signature = type.getCallSignatures()[0];
    const parameter = signature?.parameters[0];
    if (!parameter) return { props: {}, dials: {} };
    const propsType = checker.getTypeOfSymbolAtLocation(parameter, source);
    const props: Record<string, Sample> = {};
    const dials: Record<string, unknown> = {};
    // Props spread from an <input> or <img> type include `children`, which those elements throw on.
    const isVoid = ["accept", "srcSet"].some((name) => checker.getPropertyOfType(propsType, name));
    for (const property of checker.getPropertiesOfType(propsType)) {
      if (property.name === "children" && isVoid) continue;
      if (SKIPPED_PROPS.has(property.name) || /^(on[A-Z]|aria-|data-)/.test(property.name)) continue;
      const declared = property.declarations?.[0];
      if (declared?.getSourceFile().fileName.includes("node_modules") && property.name !== "children") continue;
      const isOptional = Boolean(property.flags & ts.SymbolFlags.Optional);
      const propertyType = checker.getTypeOfSymbolAtLocation(property, source);
      const value = STARTS_OPEN.test(property.name) ? true : this.generate(checker, propertyType, property.name, 0, 0, new Set());
      if (isOptional && property.name !== "children" && !STARTS_OPEN.test(property.name)) {
        const dial = this.dialFor(propertyType, undefined);
        if (dial !== undefined) dials[property.name] = dial;
        continue;
      }
      if (value === undefined) continue;
      props[property.name] = value;
      const dial = this.dialFor(propertyType, value);
      if (dial !== undefined) dials[property.name] = dial;
    }
    return { props, dials };
  }

  private dialFor(type: ts.Type, value: Sample | undefined): unknown {
    const members = type.isUnion() ? type.types.filter((each) => !(each.flags & (ts.TypeFlags.Undefined | ts.TypeFlags.Null))) : [type];
    const literals = members.filter((each) => each.isStringLiteral()).map((each) => (each as ts.StringLiteralType).value);
    if (literals.length > 1 && literals.length === members.length) return { type: "select", options: literals, default: typeof value === "string" ? value : literals[0] };
    if (members.every((each) => each.flags & (ts.TypeFlags.Boolean | ts.TypeFlags.BooleanLiteral))) return typeof value === "boolean" ? value : false;
    if (value === undefined) return undefined;
    if (typeof value === "number") return [value, Math.min(0, value), Math.max(10, value * 3), 1];
    if (typeof value === "string" && !value.startsWith("data:") && value !== "#") return { type: "text", default: value };
    return undefined;
  }

  private generate(checker: ts.TypeChecker, type: ts.Type, name: string, order: number, depth: number, seen: Set<ts.Type>): Sample | undefined {
    if (depth > 6) return undefined;
    if (type.isUnion()) {
      const present = type.types.filter((each) => !(each.flags & (ts.TypeFlags.Undefined | ts.TypeFlags.Null)));
      const best = present.find((each) => each.flags & (ts.TypeFlags.StringLike | ts.TypeFlags.NumberLike)) ?? present[0];
      if (present.every((each) => each.flags & ts.TypeFlags.BooleanLiteral)) return false;
      return best ? this.generate(checker, best, name, order, depth, seen) : null;
    }
    if (type.isStringLiteral()) return type.value;
    if (type.isNumberLiteral()) return type.value;
    if (type.flags & ts.TypeFlags.BooleanLike) return false;
    if (type.flags & ts.TypeFlags.StringLike) return hinted(name, order);
    if (type.flags & ts.TypeFlags.NumberLike) return hintedNumber(name, order);
    if (type.flags & (ts.TypeFlags.Null | ts.TypeFlags.Undefined | ts.TypeFlags.Void)) return null;
    if (type.flags & (ts.TypeFlags.Any | ts.TypeFlags.Unknown)) return hinted(name, order);
    if (type.getCallSignatures().length > 0) return { __fn: true };
    const text = checker.typeToString(type);
    if (/^(ReactNode|ReactElement|JSX\.Element|Element)\b/.test(text) || /ReactElement|ReactPortal/.test(text)) return hinted(name, order);
    if (text === "Date") return { __date: new Date(Date.UTC(2026, 5, 1 + order)).toISOString() };
    if (seen.has(type)) return undefined;
    const nextSeen = new Set(seen).add(type);
    if (checker.isArrayType(type) || checker.isTupleType(type)) {
      const args = checker.getTypeArguments(type as ts.TypeReference);
      if (checker.isTupleType(type)) return args.map((each, at) => this.generate(checker, each, name, at, depth + 1, nextSeen) ?? null);
      const item = args[0];
      if (!item) return [];
      const singular = name.replace(/s$/, "");
      const out: Sample[] = [];
      for (let at = 0; at < 3; at++) {
        const value = this.generate(checker, item, singular, at, depth + 1, nextSeen);
        if (value !== undefined) out.push(value);
      }
      return out;
    }
    if (/^(Map|Set|WeakMap|WeakSet|Promise|RefObject|MutableRefObject|Ref)\b/.test(text)) return undefined;
    const out: Record<string, Sample> = {};
    for (const property of checker.getPropertiesOfType(type)) {
      if (property.flags & ts.SymbolFlags.Optional) continue;
      const value = this.generate(checker, checker.getTypeOfSymbol(property), property.name, order, depth + 1, nextSeen);
      if (value !== undefined) out[property.name] = value;
    }
    return out;
  }
}
