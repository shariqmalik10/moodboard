export type PaperValue = string | number;

export type PaperNode = {
  tag: string;
  attrs: Record<string, PaperValue>;
  style: Record<string, PaperValue>;
  children: (PaperNode | string)[];
};

const ENTITIES: Record<string, string> = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: " " };

function decode(text: string) {
  return text.replace(/&(#x?[\da-f]+|\w+);/gi, (whole, name: string) => {
    if (name[0] !== "#") return ENTITIES[name] ?? whole;
    const code = name[1].toLowerCase() === "x" ? Number.parseInt(name.slice(2), 16) : Number.parseInt(name.slice(1), 10);
    return String.fromCodePoint(code);
  });
}

/** JSX's own rule for text: whitespace containing a line break collapses away, and lines join with one space. */
function jsxText(raw: string) {
  const lines = raw.split(/\r?\n/);
  const kept = lines
    .map((line, at) => {
      let out = line.replace(/\t/g, " ");
      if (at > 0) out = out.replace(/^ +/, "");
      if (at < lines.length - 1) out = out.replace(/ +$/, "");
      return out;
    })
    .filter((line) => line.length > 0);
  return decode(kept.join(" "));
}

/**
 * Reads the JSX Paper exports: plain tags, string attributes, a style object, and text. It reads this
 * small grammar and nothing else, and it never evaluates anything, so a design can't run as code.
 */
export function parseJsx(source: string): PaperNode {
  let at = 0;

  const fail = (what: string): never => {
    throw new Error(`Paper's JSX has ${what} at character ${at}: ${source.slice(at, at + 40)}`);
  };
  const space = () => {
    while (at < source.length && /\s/.test(source[at])) at++;
  };
  const eat = (text: string) => {
    if (!source.startsWith(text, at)) fail(`no ${text}`);
    at += text.length;
  };

  function stringLiteral(): string {
    const quote = source[at];
    at++;
    let out = "";
    while (at < source.length && source[at] !== quote) {
      if (source[at] === "\\") {
        const next = source[at + 1];
        out += next === "n" ? "\n" : next === "t" ? "\t" : next === "u" ? String.fromCharCode(Number.parseInt(source.slice(at + 2, at + 6), 16)) : next;
        at += next === "u" ? 6 : 2;
      } else {
        out += source[at];
        at++;
      }
    }
    eat(quote);
    return out;
  }

  function literal(): PaperValue {
    space();
    if (source[at] === "'" || source[at] === '"' || source[at] === "`") return stringLiteral();
    const number = /^-?\d*\.?\d+/.exec(source.slice(at, at + 32));
    if (!number) return fail("a value that isn't a string or a number");
    at += number[0].length;
    return Number(number[0]);
  }

  function styleObject() {
    const style: Record<string, PaperValue> = {};
    eat("{");
    space();
    while (source[at] !== "}") {
      const key = source[at] === "'" || source[at] === '"' ? stringLiteral() : /^[\w$-]+/.exec(source.slice(at, at + 64))?.[0];
      if (!key) return fail("a style key it can't read");
      if (source[at - 1] !== "'" && source[at - 1] !== '"') at += key.length;
      space();
      eat(":");
      style[key] = literal();
      space();
      if (source[at] === ",") {
        at++;
        space();
      }
    }
    eat("}");
    return style;
  }

  function element(): PaperNode {
    eat("<");
    const name = /^[a-zA-Z][\w.:-]*/.exec(source.slice(at, at + 64))?.[0];
    if (!name) return fail("a tag it can't read");
    at += name.length;
    const node: PaperNode = { tag: name, attrs: {}, style: {}, children: [] };

    while (true) {
      space();
      if (source.startsWith("/>", at)) {
        at += 2;
        return node;
      }
      if (source[at] === ">") {
        at++;
        break;
      }
      const attr = /^[a-zA-Z_:][\w:.-]*/.exec(source.slice(at, at + 64))?.[0];
      if (!attr) return fail("an attribute it can't read");
      at += attr.length;
      space();
      if (source[at] !== "=") {
        node.attrs[attr] = "true";
        continue;
      }
      at++;
      space();
      if (source[at] === '"' || source[at] === "'") {
        const quote = source[at];
        const end = source.indexOf(quote, at + 1);
        if (end < 0) return fail("an unfinished attribute");
        node.attrs[attr] = decode(source.slice(at + 1, end));
        at = end + 1;
        continue;
      }
      eat("{");
      space();
      if (attr === "style") node.style = styleObject();
      else node.attrs[attr] = literal();
      space();
      eat("}");
    }

    while (true) {
      if (at >= source.length) return fail("an unclosed tag");
      if (source.startsWith("</", at)) {
        at += 2;
        eat(name);
        space();
        eat(">");
        return node;
      }
      if (source[at] === "<") {
        node.children.push(element());
      } else if (source[at] === "{") {
        at++;
        const value = literal();
        space();
        eat("}");
        node.children.push(String(value));
      } else {
        let end = at;
        while (end < source.length && source[end] !== "<" && source[end] !== "{") end++;
        const text = jsxText(source.slice(at, end));
        if (text) node.children.push(text);
        at = end;
      }
    }
  }

  space();
  if (source[at] === "(") at++;
  space();
  return element();
}
