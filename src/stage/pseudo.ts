/**
 * The scripted cursor can't trigger `:hover`, since only a real pointer sets it. So every rule that
 * names a pseudo-state also matches a class, and the director sets the class on what it points at.
 * The component's own stylesheet then responds as it does to a real pointer.
 */
export const PSEUDO = { hover: "__hover", active: "__active", focusVisible: "__focus" } as const;

const REWRITES: [RegExp, string][] = [
  [/:hover\b/g, `.${PSEUDO.hover}`],
  [/:active\b/g, `.${PSEUDO.active}`],
  [/:focus-visible\b/g, `.${PSEUDO.focusVisible}`],
];

function teach(rules: CSSRuleList) {
  for (const rule of Array.from(rules)) {
    if (rule instanceof CSSStyleRule) {
      const original = rule.selectorText;
      const taught = REWRITES.reduce((selector, [from, to]) => selector.replace(from, to), original);
      if (taught !== original) rule.selectorText = `${original}, ${taught}`;
    }
    if ("cssRules" in rule) teach((rule as CSSGroupingRule).cssRules);
  }
}

const seen = new WeakSet<CSSStyleSheet>();

/** A dial's stylesheet is rewritten as it moves, so its rules get the classes added again each time. */
export function teachSheet(sheet: CSSStyleSheet | null) {
  if (sheet) teach(sheet.cssRules);
}

function teachAll() {
  for (const sheet of Array.from(document.styleSheets)) {
    if (seen.has(sheet)) continue;
    try {
      teach(sheet.cssRules);
      seen.add(sheet);
    } catch {
      // A stylesheet that is still loading, or cross-origin, has no readable rules yet.
    }
  }
}

/** Adds the classes to every stylesheet loaded now and to any a lazily imported component loads later. */
export function watchPseudoStates() {
  teachAll();
  new MutationObserver(teachAll).observe(document.head, { childList: true, subtree: true, characterData: true });
  document.addEventListener("load", teachAll, true);
}
