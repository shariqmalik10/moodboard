/** A local font in a card keeps the project's fallback stack, since the file path means nothing outside Next's loader. */
export default function localFont() {
  return { className: "", variable: "", style: {} };
}
