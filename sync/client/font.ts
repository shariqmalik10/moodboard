type Options = { variable?: string; weight?: string | string[]; style?: string | string[]; axes?: string[] };

const loaded = new Set<string>();

function link(family: string, options: Options) {
  const name = family.replace(/_/g, " ");
  if (loaded.has(name)) return name;
  loaded.add(name);
  const query = name.replace(/ /g, "+");
  const element = Object.assign(document.createElement("link"), { rel: "stylesheet", href: `https://fonts.googleapis.com/css2?family=${query}:wght@100..900&display=swap` });
  // A font without a variable weight range fails the request above, so it falls back to the plain one.
  element.onerror = () => {
    element.onerror = null;
    const weights = [options.weight].flat().filter(Boolean).join(";");
    element.href = `https://fonts.googleapis.com/css2?family=${query}${weights ? `:wght@${weights}` : ""}&display=swap`;
  };
  document.head.append(element);
  return name;
}

/** What a font from the root layout would have put on `<html>`. */
export function applyFont(family: string, source: string, options: Options) {
  if (source !== "google") return;
  const name = link(family, options);
  if (options.variable) document.documentElement.style.setProperty(options.variable, `"${name}"`);
}

/** `next/font/google`'s export: each family is a function, and the classes it would generate become inline styles. */
export const googleFont = (family: string) => (options: Options = {}) => {
  const name = link(family, options);
  if (options.variable) document.documentElement.style.setProperty(options.variable, `"${name}"`);
  return { className: "", variable: "", style: { fontFamily: `"${name}"` } };
};
